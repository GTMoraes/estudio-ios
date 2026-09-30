import Foundation
import AVFoundation

/// Padrão de nome de saída ({nome} {data} {datahora} …), guardado por tipo de trabalho.
enum PadraoNome {
    enum Tipo: String { case transcricao, voz, conversao, link }

    static func ler(_ t: Tipo) -> String {
        UserDefaults.standard.string(forKey: "padraoNome." + t.rawValue) ?? Renomear.padrao
    }
    static func gravar(_ p: String, _ t: Tipo) {
        UserDefaults.standard.set(p, forKey: "padraoNome." + t.rawValue)
    }

    static func personalizado(_ p: String) -> Bool {
        let t = p.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != Renomear.padrao
    }

    /// Nome base (sem extensão) de um resultado. {nome} = nome do original sem a extensão.
    static func base(_ nomeOriginal: String, padrao: String, data: Date, largura: Int? = nil, altura: Int? = nil) -> String {
        let b = (nomeOriginal as NSString).deletingPathExtension
        let limpo = Nuvem.limpar(b.isEmpty ? "arquivo" : b)
        guard personalizado(padrao) else { return limpo }
        return Nuvem.limpar(Renomear.aplicar(padrao, nome: limpo, largura: largura, altura: altura, data: data))
    }

    /// Troca o nome de um arquivo já gravado para `base` + a extensão dele (+ sufixo), sem sobrescrever.
    static func renomear(_ u: URL, base: String, sufixo: String = "") -> URL {
        let ext = u.pathExtension
        let alvo = u.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? base + sufixo : "\(base)\(sufixo).\(ext)")
        if alvo.lastPathComponent == u.lastPathComponent { return u }
        let destino = Nuvem.semColisao(alvo)
        return (try? FileManager.default.moveItem(at: u, to: destino)) != nil ? destino : u
    }
}

/// Data de gravação de um áudio/vídeo (metadado do arquivo); se não tiver, a data do arquivo.
enum DataMidia {
    static func ler(_ url: URL) async -> Date {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate), let d = try? await item.load(.dateValue) {
            return d
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) ?? Date()
    }
}
