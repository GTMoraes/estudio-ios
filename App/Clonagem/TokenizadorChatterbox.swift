import Foundation

/// O tokenizador de letras do Chatterbox multilíngue (grapheme_mtl_merged_expanded_v1.json), refeito em
/// Swift com o mesmo caminho do original em Python:
/// pontuação (punc_norm) → minúsculas → NFKD → "[pt]" na frente → espaço vira "[SPACE]" →
/// tokens especiais → pré-tokenizador Whitespace (\w+|[^\w\s]+) → BPE.
/// O config.json do modelo traz frases com os tokens do original para conferir (`conferir`).
final class TokenizadorChatterbox: @unchecked Sendable {
    // chaves pelos escalares Unicode: String do Swift trata "ã" e "a"+"~" como iguais, o original não
    private let vocab: [[UInt32]: Int]
    private let ranks: [[UInt32]: Int]            // a + [separador] + b -> ordem da junção
    private static let sep: UInt32 = 0xFFFF_FFFF
    private let especiais: [(String, Int)]        // do maior para o menor
    private let desconhecido: Int
    private let regex: NSRegularExpression

    init(arquivo: URL) throws {
        guard let j = try JSONSerialization.jsonObject(with: Data(contentsOf: arquivo)) as? [String: Any],
              let modelo = j["model"] as? [String: Any],
              let v = modelo["vocab"] as? NSDictionary else {
            throw ErroApp("O tokenizer.json do Chatterbox está num formato inesperado.")
        }
        func esc(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
        var voc: [[UInt32]: Int] = [:]
        for (k, id) in v { if let k = k as? String, let id = id as? Int { voc[esc(k)] = id } }
        vocab = voc
        var r: [[UInt32]: Int] = [:]
        if let ms = modelo["merges"] as? [Any] {
            for (i, m) in ms.enumerated() {
                var par: [String]?
                if let s = m as? String {
                    let p = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    if p.count == 2 { par = p }
                } else if let p = m as? [String], p.count == 2 { par = p }
                if let p = par { r[esc(p[0]) + [Self.sep] + esc(p[1])] = i }
            }
        }
        ranks = r
        var esp: [(String, Int)] = []
        for a in (j["added_tokens"] as? [[String: Any]]) ?? [] {
            if let c = a["content"] as? String, let id = a["id"] as? Int, !c.isEmpty { esp.append((c, id)) }
        }
        especiais = esp.sorted { $0.0.count > $1.0.count }
        desconhecido = voc[esc((modelo["unk_token"] as? String) ?? "[UNK]")] ?? 1
        regex = try NSRegularExpression(pattern: "\\w+|[^\\w\\s]+")
    }

    /// Tokens do texto, sem o início/fim (o motor põe 255 … 0).
    func codificar(_ texto: String, idioma: String = "pt") -> [Int] {
        var t = Self.pontuacao(texto).lowercased().decomposedStringWithCompatibilityMapping
        t = "[\(idioma.lowercased())]" + t
        t = t.replacingOccurrences(of: " ", with: "[SPACE]")
        var saida: [Int] = []
        var comum = ""
        var i = t.startIndex
        while i < t.endIndex {
            var achou = false
            for (c, id) in especiais where t[i...].hasPrefix(c) {
                if !comum.isEmpty { saida += pedaco(comum); comum = "" }
                saida.append(id)
                i = t.index(i, offsetBy: c.count)
                achou = true
                break
            }
            if !achou { comum.append(t[i]); i = t.index(after: i) }
        }
        if !comum.isEmpty { saida += pedaco(comum) }
        return saida
    }

    /// Pré-tokenização Whitespace e BPE de cada palavra.
    private func pedaco(_ s: String) -> [Int] {
        let ns = s as NSString
        var ids: [Int] = []
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            ids += bpe(ns.substring(with: m.range))
        }
        return ids
    }

    private func bpe(_ palavra: String) -> [Int] {
        // símbolos = escalares Unicode (como o Rust), não "Character": o NFKD separa a letra do acento
        var simb: [[UInt32]] = palavra.unicodeScalars.map { [$0.value] }
        while simb.count > 1 {
            var melhor = Int.max, onde = -1
            for k in 0..<(simb.count - 1) {
                if let r = ranks[simb[k] + [Self.sep] + simb[k + 1]], r < melhor { melhor = r; onde = k }
            }
            if onde < 0 { break }
            let a = simb[onde], b = simb[onde + 1]
            var novo: [[UInt32]] = []
            novo.reserveCapacity(simb.count)
            var k = 0
            while k < simb.count {
                if k < simb.count - 1 && simb[k] == a && simb[k + 1] == b { novo.append(a + b); k += 2 }
                else { novo.append(simb[k]); k += 1 }
            }
            simb = novo
        }
        return simb.map { vocab[$0] ?? desconhecido }
    }

    /// O punc_norm do Chatterbox.
    static func pontuacao(_ entrada: String) -> String {
        if entrada.isEmpty { return "You need to add some text for me to talk." }
        var t = entrada
        if let p = t.first, p.isLowercase { t = p.uppercased() + t.dropFirst() }
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for (a, b) in [("...", ", "), ("…", ", "), (":", ","), (" - ", ", "), (";", ", "), ("—", "-"), ("–", "-"),
                       (" ,", ","), ("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        while t.hasSuffix(" ") { t.removeLast() }
        let fins: Set<String> = [".", "!", "?", "-", ",", "、", "，", "。", "？", "！"]
        if !fins.contains(where: { t.hasSuffix($0) }) { t += "." }
        return t
    }
}
