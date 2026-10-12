import Foundation

struct PalavraTempo: Codable {
    var p: String
    var i: Double?
    var f: Double?
}

/// Tempos das palavras de um trecho, pelo mesmo método do pacote oficial
/// (`extract_word_timings`): atenção do modelo + energia do mel, alinhadas por Viterbi.
/// Parâmetros padrão do pacote: nitidez 5, silêncio com gama 3 e penalidade 3, janela inteira
/// de 30 s e divisão das folgas de até 0,1 s entre palavras vizinhas.
enum CrisperTempos {
    private static let marcadores: Set<String> = ["<ctx>", "<ectx>", "<htx>", "<ehtx>", "<vtx>", "<evtx>", "<sot>", "<eot>"]

    private static func especial(_ p: String) -> Bool {
        (p.hasPrefix("<|") && p.hasSuffix("|>")) || p.hasPrefix("[verbatim_") || p.hasPrefix("[intended_") || marcadores.contains(p)
    }

    /// Agrupa os tokens em palavras (índices dos tokens de cada palavra).
    static func grupos(_ ids: [Int], _ pecas: [String]) -> [[Int]] {
        var g: [[Int]] = []
        var cur: [Int] = []
        var txt = ""
        func fecha() {
            if !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !cur.isEmpty { g.append(cur) }
            cur = []; txt = ""
        }
        for (i, (t, p)) in zip(ids, pecas).enumerated() {
            if especial(p) { fecha(); continue }
            if t == 220 || p == " " { fecha(); continue }
            if p.hasPrefix(" ") && !txt.isEmpty { fecha() }
            cur.append(i); txt += p
        }
        fecha()
        return g
    }

    private static func percentil(_ v: [Float], _ q: Double) -> Double {
        let s = v.sorted()
        let x = q / 100 * Double(s.count - 1)
        let lo = Int(x.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return Double(s[lo]) + Double(s[hi] - s[lo]) * (x - Double(lo))
    }

    /// `atencao`: uma linha de 1500 quadros por token. `mel`: [128][3000].
    /// Devolve uma entrada por palavra (tempo nil quando não deu para posicionar), em segundos do trecho.
    static func calcular(ids: [Int], atencao: [[Float]], mel: [[Float]], tok: CrisperTokenizador) -> [PalavraTempo] {
        let T = min(ids.count, atencao.count)
        guard T > 0, let F = atencao.first?.count, F > 0 else { return [] }
        let pecas = ids.map { tok.peca($0) }
        let g = grupos(ids, pecas)
        guard !g.isEmpty else { return [] }
        let textos = g.map { idx in tok.decodificar(idx.map { ids[$0] }).trimmingCharacters(in: .whitespacesAndNewlines) }

        // log-probabilidade de cada token por quadro (atenção ^5, normalizada)
        var tokLogp = Array(repeating: [Float](), count: T)
        for k in 0..<T {
            var a = atencao[k].map { Double(max(0, $0)) }
            for f in 0..<a.count { a[f] = pow(a[f], 5) }
            let s = max(a.reduce(0, +), 1e-8)
            tokLogp[k] = a.map { Float(log($0 / s + 1e-8)) }
        }

        // "silêncio" por quadro a partir da energia do mel
        let nMel = mel.count, nQ = mel.first?.count ?? 0
        var energia = Array(repeating: Float(0), count: nQ)
        for t in 0..<nQ {
            var s: Float = 0
            for c in 0..<nMel { s += mel[c][t] }
            energia[t] = s / Float(nMel)
        }
        let p10 = percentil(energia, 10), p90 = percentil(energia, 90)
        let d = max(1e-6, p90 - p10)
        let norm = energia.map { min(1, max(0, (Double($0) - p10) / d)) }
        var branco = Array(repeating: Float(0), count: F)
        for j in 0..<F {
            let x = F > 1 ? Double(j) / Double(F - 1) * Double(nQ - 1) : 0
            let lo = Int(x.rounded(.down)), hi = min(lo + 1, nQ - 1)
            let e = norm[lo] + (norm[hi] - norm[lo]) * (x - Double(lo))
            var b = min(1 - 1e-4, max(1e-4, 1 - e))
            b = min(1, max(1e-4, pow(b, 3)))
            branco[j] = Float(log(b + 1e-6) - 3)
        }

        // emissão de cada palavra = logsumexp dos seus tokens
        let W = g.count
        var palavra = Array(repeating: Array(repeating: Float(-1e9), count: F), count: W)
        for (w, idx) in g.enumerated() {
            let v = idx.filter { $0 >= 0 && $0 < T }
            guard !v.isEmpty else { continue }
            for f in 0..<F {
                var m = -Double.infinity
                for i in v { m = max(m, Double(tokLogp[i][f])) }
                var s = 0.0
                for i in v { s += exp(Double(tokLogp[i][f]) - m) }
                palavra[w][f] = Float(m + log(s))
            }
        }

        // Viterbi: estados [branco0, palavra0, branco1, …, brancoW]
        let S = 2 * W + 1
        let neg: Float = -1e9
        func emit(_ s: Int, _ f: Int) -> Float { s % 2 == 0 ? branco[f] : palavra[(s - 1) / 2][f] }
        var prev = Array(repeating: neg, count: S)
        prev[0] = emit(0, 0)
        var volta = Array(repeating: Array(repeating: UInt8(0), count: F), count: S)
        var cur = Array(repeating: Float(0), count: S)
        for f in 1..<F {
            for s in 0..<S {
                let fica = prev[s]
                let avanca = s > 0 ? prev[s - 1] : neg
                if avanca > fica { cur[s] = avanca + emit(s, f); volta[s][f] = 1 }
                else { cur[s] = fica + emit(s, f) }
            }
            swap(&prev, &cur)
        }
        var fim = 0
        var melhor = -Float.infinity
        for s in 0..<S {
            let v = prev[s] + Float(s) * 1e-4
            if v > melhor { melhor = v; fim = s }
        }
        var estados = Array(repeating: 0, count: F)
        var s = fim
        var f = F - 1
        while f >= 0 {
            estados[f] = s
            if f == 0 { break }
            if volta[s][f] == 1 { s -= 1 }
            f -= 1
        }
        var tempos: [(Double?, Double?)] = Array(repeating: (nil, nil), count: W)
        var primeiro = Array(repeating: -1, count: W), ultimo = Array(repeating: -1, count: W)
        for (q, e) in estados.enumerated() where e % 2 == 1 {
            let w = (e - 1) / 2
            if primeiro[w] < 0 { primeiro[w] = q }
            ultimo[w] = q
        }
        for w in 0..<W where primeiro[w] >= 0 { tempos[w] = (Double(primeiro[w]) * 0.02, Double(ultimo[w]) * 0.02) }

        // divide folgas curtas (até 0,1 s) entre as palavras posicionadas
        let postas = (0..<W).filter { tempos[$0].0 != nil }
        if postas.count >= 2 {
            for k in 0..<(postas.count - 1) {
                let a = postas[k], b = postas[k + 1]
                let folga = tempos[b].0! - tempos[a].1!
                if folga > 0 && folga <= 0.1 {
                    let meio = tempos[a].1! + folga / 2
                    tempos[a].1 = meio; tempos[b].0 = meio
                }
            }
        }
        return (0..<W).map { PalavraTempo(p: textos[$0], i: tempos[$0].0, f: tempos[$0].1) }
    }
}
