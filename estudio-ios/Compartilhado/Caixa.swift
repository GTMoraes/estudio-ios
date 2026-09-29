import Foundation

/// Grupo de apps compartilhado entre o app e a extensão de compartilhar.
/// A AltStore troca o identificador na hora de assinar e grava o nome real
/// em "ALTAppGroups" no Info.plist; por isso ele é lido de lá primeiro.
enum GrupoApp {
    static let padrao = "group.com.gtm.estudio"

    static var id: String {
        if let grupos = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], !grupos.isEmpty {
            return grupos.first(where: { $0.contains("estudio") }) ?? grupos[0]
        }
        return padrao
    }

    static var pasta: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: padrao)
    }
}

/// Algo que chegou pelo "Compartilhar" e ainda não foi aberto no app.
struct Recebido: Codable, Identifiable, Equatable {
    enum Tipo: String, Codable { case link, arquivo }
    var id: String
    var tipo: Tipo
    var link: String?
    var arquivo: String?      // nome do arquivo dentro da caixa
    var nome: String
    var data: Date
}

/// Caixa de entrada no grupo de apps: a extensão grava, o app lê e esvazia.
enum Caixa {
    static var pasta: URL? {
        guard let base = GrupoApp.pasta else { return nil }
        let url = base.appendingPathComponent("Caixa", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func guardar(_ r: Recebido) throws {
        guard let pasta else { throw NSError(domain: "Caixa", code: 1, userInfo: [NSLocalizedDescriptionKey: "grupo de apps indisponível"]) }
        let dados = try JSONEncoder().encode(r)
        try dados.write(to: pasta.appendingPathComponent("\(r.id).json"), options: .atomic)
    }

    /// Guarda uma cópia do arquivo na caixa e devolve o nome usado.
    static func copiar(_ origem: URL, id: String) throws -> String {
        guard let pasta else { throw NSError(domain: "Caixa", code: 1, userInfo: [NSLocalizedDescriptionKey: "grupo de apps indisponível"]) }
        let nome = "\(id)-\(origem.lastPathComponent)"
        let destino = pasta.appendingPathComponent(nome)
        try? FileManager.default.removeItem(at: destino)
        try FileManager.default.copyItem(at: origem, to: destino)
        return nome
    }

    static func pendentes() -> [Recebido] {
        guard let pasta,
              let nomes = try? FileManager.default.contentsOfDirectory(atPath: pasta.path) else { return [] }
        return nomes.filter { $0.hasSuffix(".json") }
            .compactMap { try? JSONDecoder().decode(Recebido.self, from: Data(contentsOf: pasta.appendingPathComponent($0))) }
            .sorted { $0.data < $1.data }
    }

    static func url(doArquivo r: Recebido) -> URL? {
        guard let pasta, let a = r.arquivo else { return nil }
        return pasta.appendingPathComponent(a)
    }

    /// Tira o recebido da caixa. `manterArquivo`: o app já moveu o arquivo.
    static func remover(_ r: Recebido) {
        guard let pasta else { return }
        try? FileManager.default.removeItem(at: pasta.appendingPathComponent("\(r.id).json"))
        if let a = r.arquivo { try? FileManager.default.removeItem(at: pasta.appendingPathComponent(a)) }
    }
}

/// Primeiro link http(s) dentro de um texto (o Instagram manda texto + link).
func primeiroLink(em texto: String) -> URL? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
    let alcance = NSRange(texto.startIndex..., in: texto)
    for m in detector.matches(in: texto, options: [], range: alcance) {
        if let u = m.url, let s = u.scheme?.lowercased(), s == "http" || s == "https" { return u }
    }
    return nil
}
