import Foundation

/// O "dicionário" do CrisperWhisper (tokenizer.json): texto ↔ números do modelo.
/// Mesmo algoritmo do tokenizador oficial (BPE em bytes, com os tokens extras do CrisperWhisper);
/// conferido contra ele em 101 frases, incluindo os contextos do áudio de teste.
final class CrisperTokenizador: @unchecked Sendable {
    private var vocab: [String: Int] = [:]
    private var porId: [Int: String] = [:]
    private var ranks: [String: Int] = [:]            // "a b" -> ordem da junção
    private var extras: [String: Int] = [:]           // tokens adicionados ([UH], <ctx>, <|pt|>…)
    private var extrasOrdenados: [String] = []        // do mais longo ao mais curto
    private var iniciaisExtras: Set<Character> = []   // todos começam com "<" ou "[": evita procurar à toa
    private(set) var idsExtras: Set<Int> = []
    private var byteParaChar: [Character] = []
    private var charParaByte: [Character: UInt8] = [:]
    private let padrao: NSRegularExpression
    private var cache: [String: [String]] = [:]

    /// Os que não aparecem no texto (iguais ao `all_special_ids` do pacote oficial).
    private(set) var especiais: Set<Int> = []

    let eot = 50257
    private(set) var sot = 50258
    private(set) var transcrever = 50360
    private(set) var semTempos = 50364

    init(arquivo: URL) throws {
        padrao = try NSRegularExpression(pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+")
        let dados = try Data(contentsOf: arquivo)
        guard let raiz = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let modelo = raiz["model"] as? [String: Any],
              let v = modelo["vocab"] as? [String: Int],
              let merges = modelo["merges"] as? [Any] else {
            throw ErroApp("O tokenizer.json do CrisperWhisper não está no formato esperado.")
        }
        vocab = v
        for (k, i) in v { porId[i] = k }
        for (n, m) in merges.enumerated() {
            if let par = m as? [String], par.count == 2 { ranks[par[0] + " " + par[1]] = n }
            else if let s = m as? String { ranks[s] = n }
        }
        for a in (raiz["added_tokens"] as? [[String: Any]]) ?? [] {
            guard let c = a["content"] as? String, let i = a["id"] as? Int else { continue }
            extras[c] = i; porId[i] = c; idsExtras.insert(i)
        }
        extrasOrdenados = extras.keys.sorted { $0.count > $1.count }
        iniciaisExtras = Set(extras.keys.compactMap { $0.first })
        // tabela byte -> caractere do BPE em bytes (a mesma do GPT-2)
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        byteParaChar = Array(repeating: " ", count: 256)
        for (b, c) in zip(bs, cs) {
            let ch = Character(Unicode.Scalar(UInt32(c))!)
            byteParaChar[b] = ch; charParaByte[ch] = UInt8(b)
        }
        for (k, i) in vocab.merging(extras, uniquingKeysWith: { a, _ in a }) {
            if k.hasPrefix("<|") && k.hasSuffix("|>") { especiais.insert(i) }
            else if k.hasPrefix("[verbatim_") || k.hasPrefix("[intended_") { especiais.insert(i) }
            else if ["<vtx>", "<evtx>", "<htx>", "<ehtx>", "<ctx>", "<ectx>"].contains(k) { especiais.insert(i) }
        }
        if let i = extras["<|startoftranscript|>"] { sot = i }
        if let i = extras["<|transcribe|>"] { transcrever = i }
        if let i = extras["<|notimestamps|>"] { semTempos = i }
        especiais.formUnion([eot, sot, transcrever, semTempos])
    }

    func id(_ token: String) -> Int? { extras[token] ?? vocab[token] }

    // MARK: texto -> números

    func codificar(_ texto: String) -> [Int] {
        var ids: [Int] = []
        var trecho = ""
        var i = texto.startIndex
        while i < texto.endIndex {
            if iniciaisExtras.contains(texto[i]),
               let achado = extrasOrdenados.first(where: { texto[i...].hasPrefix($0) }) {
                if !trecho.isEmpty { ids += codificarTrecho(trecho); trecho = "" }
                ids.append(extras[achado]!)
                i = texto.index(i, offsetBy: achado.count)
            } else {
                trecho.append(texto[i]); i = texto.index(after: i)
            }
        }
        if !trecho.isEmpty { ids += codificarTrecho(trecho) }
        return ids
    }

    private func codificarTrecho(_ s: String) -> [Int] {
        let ns = s as NSString
        var ids: [Int] = []
        for m in padrao.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let pedaco = ns.substring(with: m.range)
            let u = String(pedaco.utf8.map { byteParaChar[Int($0)] })
            for p in bpe(u) { if let i = vocab[p] { ids.append(i) } }
        }
        return ids
    }

    private func bpe(_ palavra: String) -> [String] {
        if let c = cache[palavra] { return c }
        var partes = palavra.map { String($0) }
        while partes.count > 1 {
            var melhor: (rank: Int, i: Int)?
            for i in 0..<(partes.count - 1) {
                if let r = ranks[partes[i] + " " + partes[i + 1]], melhor == nil || r < melhor!.rank { melhor = (r, i) }
            }
            guard let m = melhor else { break }
            let a = partes[m.i], b = partes[m.i + 1]
            var nova: [String] = []
            var i = 0
            while i < partes.count {
                if i < partes.count - 1 && partes[i] == a && partes[i + 1] == b { nova.append(a + b); i += 2 }
                else { nova.append(partes[i]); i += 1 }
            }
            partes = nova
        }
        cache[palavra] = partes
        return partes
    }

    // MARK: números -> texto

    func decodificar(_ ids: [Int], pularEspeciais: Bool = true) -> String {
        var saida = ""
        var bytes: [UInt8] = []
        for i in ids {
            if pularEspeciais && especiais.contains(i) { continue }
            guard let t = porId[i] else { continue }
            if idsExtras.contains(i) {
                saida += String(decoding: bytes, as: UTF8.self); bytes = []
                saida += t
            } else {
                for ch in t { if let b = charParaByte[ch] { bytes.append(b) } }
            }
        }
        return saida + String(decoding: bytes, as: UTF8.self)
    }

    /// Um token sozinho, sem pular nada (é o que o pacote oficial usa para achar os começos de palavra).
    func peca(_ id: Int) -> String { decodificar([id], pularEspeciais: false) }
}
