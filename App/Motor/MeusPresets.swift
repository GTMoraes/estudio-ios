import Foundation
import Observation

/// Ajustes de conversão salvos pelo usuário (o trecho não entra: é de cada arquivo).
struct PresetSalvo: Codable, Identifiable, Equatable {
    var id = UUID()
    var nome: String
    var opcoes: OpcoesConversao
}

@MainActor
@Observable
final class MeusPresets {
    static let shared = MeusPresets()

    private(set) var lista: [PresetSalvo] = []

    nonisolated private static var arquivo: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("meus-presets.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.arquivo),
           let l = try? JSONDecoder().decode([PresetSalvo].self, from: d) {
            lista = l
        }
    }

    func preset(_ id: UUID) -> PresetSalvo? { lista.first { $0.id == id } }

    @discardableResult
    func salvar(nome: String, opcoes: OpcoesConversao, substituir id: UUID? = nil) -> UUID {
        var o = opcoes
        o.inicio = nil; o.fim = nil
        let n = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, let k = lista.firstIndex(where: { $0.id == id }) {
            lista[k].opcoes = o
            if !n.isEmpty { lista[k].nome = n }
            gravar()
            return id
        }
        let p = PresetSalvo(nome: n.isEmpty ? "Meu preset \(lista.count + 1)" : n, opcoes: o)
        lista.append(p)
        gravar()
        return p.id
    }

    func remover(_ id: UUID) {
        lista.removeAll { $0.id == id }
        gravar()
    }

    private func gravar() {
        try? FileManager.default.createDirectory(at: Self.arquivo.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(lista) { try? d.write(to: Self.arquivo, options: .atomic) }
    }
}
