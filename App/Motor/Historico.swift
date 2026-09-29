import Foundation
import Observation

/// Um resultado guardado neste iPhone (Documentos/Resultados/<id>/).
struct Item: Codable, Identifiable, Equatable {
    enum Tipo: String, Codable { case transcricao, voz, video, audio }
    enum Estado: String, Codable { case processando, pronto, erro }

    var id = UUID()
    var tipo: Tipo
    var titulo: String
    var criado = Date()
    var naNuvem: Bool                 // onde foi processado
    var estado: Estado = .processando
    var mensagem: String?             // etapa atual ou erro
    var progresso: Double?            // 0...1, nil = indeterminado
    var arquivos: [String] = []       // nomes dentro da pasta do item
    var resumo: String?               // começo do texto (transcrição)
    var trabalho: String?             // job_id na nuvem (para retomar)
    var duracaoAudio: Double?
    var duracaoProcesso: Double?

    var pasta: URL { Historico.pastaResultados.appendingPathComponent(id.uuidString, isDirectory: true) }
    func url(_ nome: String) -> URL { pasta.appendingPathComponent(nome) }

    var icone: String {
        switch tipo {
        case .transcricao: return "text.quote"
        case .voz: return "waveform"
        case .video: return "film"
        case .audio: return "music.note"
        }
    }
}

@MainActor
@Observable
final class Historico {
    nonisolated static let pastaResultados: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = docs.appendingPathComponent("Resultados", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    nonisolated private static var arquivoIndice: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("historico.json")
    }

    private(set) var itens: [Item] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.arquivoIndice.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: Self.arquivoIndice),
           let lidos = try? JSONDecoder().decode([Item].self, from: d) {
            itens = lidos
        }
    }

    func item(_ id: UUID) -> Item? { itens.first { $0.id == id } }

    func adicionar(_ i: Item) {
        try? FileManager.default.createDirectory(at: i.pasta, withIntermediateDirectories: true)
        itens.insert(i, at: 0)
        salvar()
    }

    func atualizar(_ id: UUID, salvarAgora: Bool = true, _ mudar: (inout Item) -> Void) {
        guard let k = itens.firstIndex(where: { $0.id == id }) else { return }
        mudar(&itens[k])
        if salvarAgora { salvar() }
    }

    func remover(_ id: UUID) {
        guard let i = item(id) else { return }
        try? FileManager.default.removeItem(at: i.pasta)
        itens.removeAll { $0.id == id }
        salvar()
    }

    private func salvar() {
        if let d = try? JSONEncoder().encode(itens) {
            try? d.write(to: Self.arquivoIndice, options: .atomic)
        }
    }
}
