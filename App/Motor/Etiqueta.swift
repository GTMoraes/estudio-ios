import Foundation

/// Vídeo HEVC gravado com a etiqueta "hev1" (comum em Android): o iPhone só aceita "hvc1".
/// O vídeo em si é o mesmo; basta trocar os 4 bytes da etiqueta, sem regravar nada.
enum Etiqueta {
    private static let caminho: [String] = ["moov", "trak", "mdia", "minf", "stbl", "stsd"]

    /// Posição, no arquivo, da etiqueta "hev1" da trilha de vídeo; nil = não é o caso.
    static func posicao(_ url: URL) -> UInt64? {
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { return nil }
        guard let f = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? f.close() }
        guard let fim = try? f.seekToEnd() else { return nil }
        return procurar(f, de: 0, ate: fim, nivel: 0)
    }

    private static func ler(_ f: FileHandle, _ onde: UInt64, _ n: Int) -> [UInt8]? {
        do {
            try f.seek(toOffset: onde)
            guard let d = try f.read(upToCount: n), d.count == n else { return nil }
            return [UInt8](d)
        } catch { return nil }
    }

    private static func numero(_ b: ArraySlice<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for x in b { v = (v << 8) | UInt64(x) }
        return v
    }

    private static func procurar(_ f: FileHandle, de inicio: UInt64, ate fim: UInt64, nivel: Int) -> UInt64? {
        var p = inicio
        var voltas = 0
        while p + 8 <= fim, voltas < 100_000 {
            voltas += 1
            guard let c = ler(f, p, 8) else { return nil }
            var tamanho = numero(c[0..<4])
            let tipo = String(decoding: c[4..<8], as: UTF8.self)
            var cabecalho: UInt64 = 8
            if tamanho == 1 {
                guard let g = ler(f, p + 8, 8) else { return nil }
                tamanho = numero(g[0..<8]); cabecalho = 16
            } else if tamanho == 0 {
                tamanho = fim - p
            }
            guard tamanho >= cabecalho, p + tamanho <= fim else { return nil }
            if tipo == caminho[nivel] {
                let dentro = p + cabecalho
                if nivel == caminho.count - 1 {
                    // stsd: versão/marcas (4) + quantidade (4) + primeira entrada: tamanho (4) + etiqueta (4)
                    if let e = ler(f, dentro + 12, 4), String(decoding: e, as: UTF8.self) == "hev1" { return dentro + 12 }
                } else if let achou = procurar(f, de: dentro, ate: p + tamanho, nivel: nivel + 1) {
                    return achou
                }
            }
            p += tamanho
        }
        return nil
    }

    /// Copia o arquivo para `destino` e troca a etiqueta na cópia. O original não é tocado.
    static func ajustar(_ origem: URL, para destino: URL) throws {
        guard let onde = posicao(origem) else { throw ErroApp("Este vídeo não é do tipo que se resolve só com o ajuste.") }
        try? FileManager.default.removeItem(at: destino)
        try FileManager.default.copyItem(at: origem, to: destino)
        let f = try FileHandle(forWritingTo: destino)
        defer { try? f.close() }
        try f.seek(toOffset: onde)
        try f.write(contentsOf: Data("hvc1".utf8))
    }
}
