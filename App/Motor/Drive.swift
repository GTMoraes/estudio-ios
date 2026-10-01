import Foundation
import Security

/// Google Drive pela API oficial (v3), com a chave de API do Gabriel (guardada no Keychain).
/// Sem login: links públicos ("qualquer pessoa com o link"). Com login (ContaGoogle): o que foi
/// compartilhado com você, Meu Drive e drives compartilhados. O download vem direto do Google.
enum Drive {
    static let base = URL(string: "https://www.googleapis.com/drive/v3/")!

    // MARK: link

    struct Link: Equatable {
        var id: String
        var pasta: Bool?                 // nil = não dá para saber pelo link (open?id=)
        var chaveRecurso: String?        // resourcekey=… de links antigos
    }

    static func ehDrive(_ s: String) -> Bool { analisar(s) != nil }

    /// Aceita /drive/folders/ID, /drive/u/0/folders/ID, /file/d/ID/…, open?id=ID, uc?id=ID.
    static func analisar(_ s: String) -> Link? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = u.host?.lowercased(), host.hasSuffix("drive.google.com") else { return nil }
        let partes = u.pathComponents
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rk = q.first { $0.name.lowercased() == "resourcekey" }?.value
        if let k = partes.firstIndex(of: "folders"), k + 1 < partes.count {
            return Link(id: partes[k + 1], pasta: true, chaveRecurso: rk)
        }
        if let k = partes.firstIndex(of: "d"), k + 1 < partes.count {
            return Link(id: partes[k + 1], pasta: false, chaveRecurso: rk)
        }
        if let id = q.first(where: { $0.name == "id" })?.value, !id.isEmpty {
            return Link(id: id, pasta: nil, chaveRecurso: rk)
        }
        return nil
    }

    // MARK: itens

    struct Item: Codable, Identifiable, Hashable {
        var id: String
        var nome: String
        var mime: String
        var tamanho: Int64?
        var modificado: Date?
        var modificadoPor: String?
        var largura: Int?
        var altura: Int?
        var duracaoMs: Int64?
        var chaveRecurso: String?
        var miniaturaLink: String?       // thumbnailLink da API (lh3…=s220)
        var publico: Bool?               // logado, mas só abriu como link público: pede com a chave

        var ehPasta: Bool { mime == "application/vnd.google-apps.folder" }
        var ehVideo: Bool { mime.hasPrefix("video/") }
        var ehImagem: Bool { mime.hasPrefix("image/") }
        var ehMidia: Bool { ehVideo || ehImagem }
        /// Docs, Planilhas, Apresentações: só exportando (PDF)
        var ehDocGoogle: Bool { mime.hasPrefix("application/vnd.google-apps.") && !ehPasta && mime != atalho }
        var ehAtalho: Bool { mime == atalho }
        private var atalho: String { "application/vnd.google-apps.shortcut" }

        var nomeArquivo: String {
            ehDocGoogle && !nome.lowercased().hasSuffix(".pdf") ? nome + ".pdf" : nome
        }
        var miniatura: URL? {
            if ehPasta { return nil }
            if let t = miniaturaLink { return URL(string: Self.tamanho(t, 400)) }
            return URL(string: "https://drive.google.com/thumbnail?id=\(id)&sz=w400")
        }
        var imagemGrande: URL? {
            if let t = miniaturaLink { return URL(string: Self.tamanho(t, 2000)) }
            return URL(string: "https://drive.google.com/thumbnail?id=\(id)&sz=w2000")
        }
        /// endereço público de miniatura (reserva, se o thumbnailLink não abrir)
        func miniaturaReserva(_ lado: Int) -> URL? {
            ehPasta ? nil : URL(string: "https://drive.google.com/thumbnail?id=\(id)&sz=w\(lado)")
        }
        /// troca o "=s220" do fim do thumbnailLink pelo tamanho pedido
        private static func tamanho(_ t: String, _ lado: Int) -> String {
            guard let r = t.range(of: "=s\\d+[^/]*$", options: .regularExpression) else { return t }
            return t.replacingCharacters(in: r, with: "=s\(lado)")
        }
        var linkWeb: String { ehPasta ? "https://drive.google.com/drive/folders/\(id)" : "https://drive.google.com/file/d/\(id)/view" }
        var duracao: Double? { duracaoMs.map { Double($0) / 1000 } }
    }

    // MARK: chave de API (Keychain)

    private static let servico = "com.gtm.estudio.drive"

    static var chave: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: servico,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func salvarChave(_ s: String) {
        apagarChave()
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: servico,
                                kSecAttrAccount as String: "api",
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                kSecValueData as String: Data(v.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func apagarChave() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: servico] as CFDictionary)
    }

    // MARK: API

    private static let campos = "id,name,mimeType,size,modifiedTime,resourceKey,lastModifyingUser(displayName),thumbnailLink,imageMediaMetadata(width,height),videoMediaMetadata(width,height,durationMillis),shortcutDetails(targetId,targetMimeType,targetResourceKey)"

    /// Com login: Authorization Bearer (vê o que foi compartilhado com você). Sem login: chave de API (só público).
    private static func pedido(_ caminho: String, _ params: [String: String], chaves: [String: String?] = [:],
                               semLogin: Bool = false) async throws -> URLRequest {
        var token: String?
        if !semLogin { token = try await ContaGoogle.shared.tokenAcesso() }
        if token == nil && chave == nil {
            throw ErroApp("Entre com a conta Google ou cadastre a chave de API (Ajustes › Google Drive).")
        }
        var c = URLComponents(url: base.appendingPathComponent(caminho), resolvingAgainstBaseURL: false)!
        var q = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        q.append(URLQueryItem(name: "supportsAllDrives", value: "true"))
        if token == nil, let chave { q.append(URLQueryItem(name: "key", value: chave)) }
        c.queryItems = q
        var r = URLRequest(url: c.url!)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let rks = chaves.compactMap { id, rk in rk.map { "\(id)/\($0)" } }
        if !rks.isEmpty { r.setValue(rks.joined(separator: ","), forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") }
        return r
    }

    /// Há como falar com o Drive (login ou chave)?
    static var configurado: Bool { ContaGoogle.logado || chave != nil }

    private static func json(_ r: URLRequest) async throws -> [String: Any] {
        let (d, resp) = try await URLSession.shared.data(for: r)
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        guard (200..<300).contains(codigo) else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(codigo)"
            if codigo == 401 { await ContaGoogle.shared.invalidar() }
            switch codigo {
            case 404 where ContaGoogle.logado:
                throw ErroApp("Não encontrei no Drive (não foi compartilhado com \(ContaGoogle.email ?? "a sua conta") ou foi apagado).")
            case 404: throw ErroApp("Não encontrei no Drive (o link não é público ou foi apagado). Entrando com a conta Google dá para abrir o que foi compartilhado com você.")
            case 401: throw ErroApp("O Google recusou o login. Tente de novo; se repetir, saia e entre de novo em Ajustes.")
            case 403 where msg.lowercased().contains("key"): throw ErroApp("A chave do Google Drive foi recusada: \(msg)")
            case 403: throw ErroApp("O Drive recusou o acesso: \(msg)")
            default: throw ErroApp("Drive: \(msg)")
            }
        }
        return obj
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private static func item(_ o: [String: Any]) -> Item {
        var i = Item(id: o["id"] as? String ?? "", nome: o["name"] as? String ?? "sem nome",
                     mime: o["mimeType"] as? String ?? "")
        i.tamanho = (o["size"] as? String).flatMap { Int64($0) }
        i.modificado = (o["modifiedTime"] as? String).flatMap { iso.date(from: $0) }
        i.modificadoPor = (o["lastModifyingUser"] as? [String: Any])?["displayName"] as? String
        i.chaveRecurso = o["resourceKey"] as? String
        i.miniaturaLink = o["thumbnailLink"] as? String
        if let m = o["imageMediaMetadata"] as? [String: Any] {
            i.largura = m["width"] as? Int; i.altura = m["height"] as? Int
        }
        if let m = o["videoMediaMetadata"] as? [String: Any] {
            i.largura = m["width"] as? Int; i.altura = m["height"] as? Int
            i.duracaoMs = (m["durationMillis"] as? String).flatMap { Int64($0) }
        }
        // atalho: aponta para o arquivo de verdade
        if let a = o["shortcutDetails"] as? [String: Any], let alvo = a["targetId"] as? String {
            i.id = alvo
            i.mime = a["targetMimeType"] as? String ?? i.mime
            i.chaveRecurso = a["targetResourceKey"] as? String
        }
        return i
    }

    /// Pede uma pasta pública conhecida do próprio Google: 404 = a chave passou; 400/403 = chave ruim.
    static func testarChave() async throws {
        do {
            guard let chave else { throw ErroApp("Sem chave.") }
            var c = URLComponents(url: base.appendingPathComponent("files/0B_invalido_teste"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "fields", value: "id"), URLQueryItem(name: "key", value: chave)]
            _ = try await json(URLRequest(url: c.url!))
        } catch let e as ErroApp where e.localizedDescription.hasPrefix("Não encontrei") {
            return
        }
    }

    static func abrir(_ l: Link) async throws -> Item {
        if let r = raizEspecial(l.id) { return r }
        let o: [String: Any]
        do {
            o = try await json(try await pedido("files/\(l.id)", ["fields": campos], chaves: [l.id: l.chaveRecurso]))
        } catch where ContaGoogle.logado && chave != nil {
            // logado mas a conta não enxerga: tenta como link público
            var p = item(try await json(try await pedido("files/\(l.id)", ["fields": campos], chaves: [l.id: l.chaveRecurso], semLogin: true)))
            p.publico = true
            if p.chaveRecurso == nil { p.chaveRecurso = l.chaveRecurso }
            return p
        }
        var i = item(o)
        if i.chaveRecurso == nil { i.chaveRecurso = l.chaveRecurso }
        return i
    }

    // MARK: lugares da conta (com login)

    static let meuDrive = "@meu"
    static let compartilhados = "@compartilhados"
    static let drivesCompartilhados = "@drives"
    private static let pastaMime = "application/vnd.google-apps.folder"

    /// "Meu Drive", "Compartilhados comigo", "Drives compartilhados": pastas de mentira para o navegador.
    static func raizEspecial(_ id: String) -> Item? {
        switch id {
        case meuDrive: return Item(id: id, nome: "Meu Drive", mime: pastaMime)
        case compartilhados: return Item(id: id, nome: "Compartilhados comigo", mime: pastaMime)
        case drivesCompartilhados: return Item(id: id, nome: "Drives compartilhados", mime: pastaMime)
        default: return nil
        }
    }

    /// Conteúdo de uma pasta: pastas primeiro, depois por nome. "Compartilhados comigo": mais recentes primeiro.
    static func listar(_ pasta: Item, limite: Int = 5000) async throws -> [Item] {
        if pasta.id == drivesCompartilhados { return try await listarDrives() }
        if pasta.publico == true { return try await listar(pasta, limite: limite, semLogin: true) }
        guard ContaGoogle.logado, chave != nil, !pasta.id.hasPrefix("@") else {
            return try await listar(pasta, limite: limite, semLogin: false)
        }
        // logado: se a conta não enxergar a pasta (link público de outra pessoa), lista como público
        do {
            let r = try await listar(pasta, limite: limite, semLogin: false)
            if !r.isEmpty { return r }
        } catch {}
        return try await listar(pasta, limite: limite, semLogin: true)
    }

    private static func listar(_ pasta: Item, limite: Int, semLogin: Bool) async throws -> [Item] {
        var todos: [Item] = []
        var pagina: String?
        repeat {
            var p = ["fields": "nextPageToken,files(\(campos))", "pageSize": "1000",
                     "includeItemsFromAllDrives": "true"]
            switch pasta.id {
            case compartilhados:
                p["q"] = "sharedWithMe = true and trashed = false"
                p["orderBy"] = "sharedWithMeTime desc"
            case meuDrive:
                p["q"] = "'root' in parents and trashed = false"
                p["orderBy"] = "folder,name_natural"
            default:
                p["q"] = "'\(pasta.id)' in parents and trashed = false"
                p["orderBy"] = "folder,name_natural"
                if ContaGoogle.logado && !semLogin { p["corpora"] = "allDrives" }   // inclui drives compartilhados
            }
            if let pagina { p["pageToken"] = pagina }
            let o = try await json(try await pedido("files", p, chaves: [pasta.id: pasta.chaveRecurso], semLogin: semLogin))
            todos += ((o["files"] as? [[String: Any]]) ?? []).map { d in
                var i = item(d)
                if semLogin && ContaGoogle.logado { i.publico = true }
                return i
            }
            pagina = o["nextPageToken"] as? String
        } while pagina != nil && todos.count < limite
        return todos
    }

    private static func listarDrives() async throws -> [Item] {
        var todos: [Item] = []
        var pagina: String?
        repeat {
            var p = ["pageSize": "100", "fields": "nextPageToken,drives(id,name)"]
            if let pagina { p["pageToken"] = pagina }
            let o = try await json(try await pedido("drives", p))
            todos += ((o["drives"] as? [[String: Any]]) ?? []).map {
                Item(id: $0["id"] as? String ?? "", nome: $0["name"] as? String ?? "Drive", mime: pastaMime)
            }
            pagina = o["nextPageToken"] as? String
        } while pagina != nil
        return todos.sorted { $0.nome.localizedStandardCompare($1.nome) == .orderedAscending }
    }

    /// Todos os arquivos da pasta e das subpastas (até `limite`), com o caminho relativo.
    static func listarTudo(_ pasta: Item, limite: Int = 2000) async throws -> [Item] {
        var saida: [Item] = []
        var fila: [Item] = [pasta]
        while let p = fila.first, saida.count < limite {
            fila.removeFirst()
            for i in try await listar(p) {
                if i.ehPasta { fila.append(i) } else { saida.append(i) }
            }
        }
        return saida
    }

    /// Endereço do conteúdo (para baixar ou tocar o vídeo sem baixar).
    static func conteudo(_ i: Item) async throws -> URLRequest {
        if i.ehDocGoogle {
            return try await pedido("files/\(i.id)/export", ["mimeType": "application/pdf"], chaves: [i.id: i.chaveRecurso],
                                    semLogin: i.publico == true)
        }
        return try await pedido("files/\(i.id)", ["alt": "media"], chaves: [i.id: i.chaveRecurso], semLogin: i.publico == true)
    }
}

extension Drive {
    /// Baixa um arquivo para `destino`, avisando os bytes recebidos. Cancelável.
    static func baixar(_ i: Item, para destino: URL, progresso: @escaping @Sendable (Int64) -> Void) async throws {
        let r = try await conteudo(i)
        final class Caixa: @unchecked Sendable {
            var obs: NSKeyValueObservation?
            var tarefa: URLSessionDownloadTask?
        }
        let caixa = Caixa()
        let (tmp, resp): (URL, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let t = URLSession.shared.downloadTask(with: r) { url, resp, erro in
                    caixa.obs = nil
                    if let erro { cont.resume(throwing: erro); return }
                    guard let url, let resp else { cont.resume(throwing: ErroApp("Download interrompido.")); return }
                    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do { try FileManager.default.moveItem(at: url, to: d); cont.resume(returning: (d, resp)) }
                    catch { cont.resume(throwing: error) }
                }
                caixa.obs = t.progress.observe(\.completedUnitCount) { p, _ in progresso(p.completedUnitCount) }
                caixa.tarefa = t
                t.resume()
            }
        } onCancel: {
            caixa.tarefa?.cancel()
        }
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(codigo) else {
            let d = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            let erro = o?["error"] as? [String: Any]
            let motivo = ((erro?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
            if motivo == "downloadQuotaExceeded" {
                throw ErroApp("o Google bloqueou por excesso de downloads deste arquivo; tente de novo em algumas horas")
            }
            throw ErroApp((erro?["message"] as? String) ?? "HTTP \(codigo)")
        }
        try? FileManager.default.removeItem(at: destino)
        try FileManager.default.moveItem(at: tmp, to: destino)
    }
}
