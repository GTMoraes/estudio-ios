import Foundation
import Observation

/// Um resultado guardado neste iPhone (Documentos/Resultados/<id>/).
struct Item: Codable, Identifiable, Equatable {
    enum Tipo: String, Codable { case transcricao, voz, video, audio, imagem, drive, pastaDrive }
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
    var baseSaida: String?            // nome de saída escolhido (padrão de nome), para retomar da nuvem
    var origens: [String: OrigemImagem]?   // imagens: arquivo convertido -> como era o original
    var origemMidia: OrigemMidia?          // conversão de vídeo: como era o original
    var origensMidia: [String: OrigemMidia]?   // lote de vídeos: arquivo convertido -> original
    var retomada: Retomada?                // trabalho no iPhone: o que é preciso para continuar
    var pedidoLink: PedidoLink?            // link: o pedido original, para "Tentar de novo"
    var pastaDrive: Drive.Item?            // pasta (ou arquivo) do Drive aberta antes: acesso rápido

    var pasta: URL { Historico.pastaResultados.appendingPathComponent(id.uuidString, isDirectory: true) }
    func url(_ nome: String) -> URL { pasta.appendingPathComponent(nome) }

    var icone: String {
        switch tipo {
        case .transcricao: return "text.quote"
        case .voz: return "waveform"
        case .video: return "film"
        case .audio: return "music.note"
        case .imagem: return "photo"
        case .drive: return "icloud.and.arrow.down"
        case .pastaDrive: return "folder.fill"
        }
    }
}

/// Como era a imagem original (para comparar na tela de detalhes; o original é apagado).
struct OrigemImagem: Codable, Equatable {
    var nome: String
    var largura: Int
    var altura: Int
    var bytes: Int64
    var tipo: String?
    var data: Date?
}

/// Tudo o que um trabalho no iPhone precisa para ser continuado depois que o app foi fechado.
/// A entrada fica em Trabalhos/<id>/entrada (ver SegundoPlano.swift).
struct Retomada: Codable, Equatable {
    enum Tipo: String, Codable { case voz, conversao, imagens, transcricao, loteConversao, drive }
    var tipo: Tipo
    var entradas: [String]            // nomes dentro de Trabalhos/<id>/entrada
    var nome: String                  // nome do arquivo original
    var base: String?                 // nome de saída já resolvido
    var data: Date?
    var voz: OpcoesVoz?
    var quadra: Bool?
    var conversao: OpcoesConversao?
    var imagem: OpcoesImagem?
    var idioma: String?
    var saidas: [String?]?            // imagens e lote: nome gravado de cada entrada (nil = falta fazer; "" = falhou)
    var falhas: [String]?
    var conversoes: [OpcoesConversao]?    // lote de vídeos: ajustes de cada um
    var bases: [String]?                  // lote de vídeos: nome de saída de cada um
    var nomes: [String]?                  // lote de vídeos: nome original de cada um
    var datas: [Date]?
    var drive: [Drive.Item]?              // download do Drive: os arquivos pedidos
    var converterDepois: Bool?
}

/// Um pedido feito a partir de um link (baixar ou transcrever), guardado para repetir.
struct PedidoLink: Codable, Equatable {
    enum Acao: String, Codable { case video, audio, transcrever }
    var info: InfoLink
    var acao: Acao
    var naNuvem: Bool
    var idioma: String
    var padrao: String
}

/// Como era o vídeo original (para comparar na tela de detalhes; o original é apagado).
struct OrigemMidia: Codable, Equatable {
    var nome: String
    var largura: Int
    var altura: Int
    var bytes: Int64
    var duracao: Double
    var fps: Double
    var codec: String
    var hdr: String
    var dolbyVision: Bool
    var ambienteLux: Double?
    var data: Date?
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
        Trabalhos.apagar(id)
        itens.removeAll { $0.id == id }
        salvar()
    }

    private func salvar() {
        if let d = try? JSONEncoder().encode(itens) {
            try? d.write(to: Self.arquivoIndice, options: .atomic)
        }
    }
}
