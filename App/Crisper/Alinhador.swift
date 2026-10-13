import Foundation
import CoreML

/// O alinhador (wav2vec2 large treinado em português, o mesmo que o WhisperX usa): mede onde cada
/// palavra começa e termina, letra por letra, no próprio áudio. O CrisperWhisper continua dizendo O QUE
/// foi falado; os tempos dele "espremem" palavras em fala rápida, e o corte comia começos e finais.
/// Fica em "No meu iPhone › Estúdio › Alinhador" (Alinhador.mlmodelc + vocab.json); se faltar, é
/// baixado de cdn.frx9.com/modelos/alinhador/.
enum ModeloAlinhador {
    static let base = URL(string: "https://cdn.frx9.com/modelos/alinhador/")!
    static let tamanhoAproximado: Int64 = 640_000_000

    static var pasta: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alinhador", isDirectory: true)
    }

    static var pronto: Bool {
        !FileManager.default.fileExists(atPath: pasta.appendingPathComponent(".incompleto").path)
            && modelo != nil && CrisperModelo.acharArquivo("vocab.json", em: pasta) != nil
    }

    static var modelo: URL? {
        guard let u = CrisperModelo.acharArquivo("Alinhador.mlmodelc", em: pasta),
              FileManager.default.fileExists(atPath: u.appendingPathComponent("coremldata.bin").path) else { return nil }
        return u
    }

    static func tamanhoEmDisco() -> Int64 { ModeloCrisper.tamanho(pasta) }
    static func apagar() { try? FileManager.default.removeItem(at: pasta) }
}

/// Alinhamento forçado (CTC Viterbi) das palavras do CrisperWhisper no áudio. Mesmo algoritmo de
/// testes/alinhador/alinhar_ref.py (conferido contra o PyTorch no workflow de conversão).
final class Alinhador: @unchecked Sendable {
    static let versao = 1
    static let amostras = 384_000                // entrada fixa: 24 s a 16 kHz
    static let janela = 20.0, contexto = 2.0, quadro = 0.02

    private let modelo: MLModel
    private let vocab: [Character: Int]
    private let branco: Int
    private let separador: Int

    init() throws {
        guard let u = ModeloAlinhador.modelo,
              let vu = CrisperModelo.acharArquivo("vocab.json", em: ModeloAlinhador.pasta) else {
            throw ErroApp("O alinhador não está no iPhone.")
        }
        let c = MLModelConfiguration()
        c.computeUnits = .cpuAndGPU
        modelo = try MLModel(contentsOf: u, configuration: c)
        guard let j = try JSONSerialization.jsonObject(with: Data(contentsOf: vu)) as? [String: Any],
              let v = j["vocab"] as? [String: Int], let b = j["branco"] as? Int, let s = j["separador"] as? Int else {
            throw ErroApp("O vocab.json do alinhador está num formato inesperado.")
        }
        let especiais = Set((j["especiais"] as? [String]) ?? [])
        var m: [Character: Int] = [:]
        for (k, id) in v where k.count == 1 && !especiais.contains(k) { m[Character(k)] = id }
        vocab = m; branco = b; separador = s
    }

    // MARK: emissões

    /// Log-probabilidades a cada 20 ms, em janelas de 24 s (20 s úteis + 2 s de contexto de cada lado).
    func emissoes(_ audio: [Float], progresso: (Double) -> Void) throws -> [[Float]] {
        let dur = Double(audio.count) / 16000
        var saida: [[Float]] = []
        var s = 0.0
        while s < dur {
            try Task.checkCancellation()
            progresso(s / dur)
            let a = max(0, s - Self.contexto), b = min(dur, s + Self.janela + Self.contexto)
            let lp = try rodar(audio, de: a, ate: b)
            let q0 = Int((s - a) / Self.quadro + 0.5)
            let q1 = q0 + Int(min(Self.janela, dur - s) / Self.quadro + 0.5)
            if q0 < lp.count { saida += lp[q0..<min(q1, lp.count)] }
            s += Self.janela
        }
        return saida
    }

    private func rodar(_ audio: [Float], de a: Double, ate b: Double) throws -> [[Float]] {
        let i0 = max(0, Int(a * 16000)), i1 = min(audio.count, Int(b * 16000))
        let n = max(0, min(i1 - i0, Self.amostras))
        var media: Double = 0, quad: Double = 0
        for k in 0..<n { let v = Double(audio[i0 + k]); media += v; quad += v * v }
        if n > 0 { media /= Double(n); quad = quad / Double(n) - media * media }
        let desvio = Float(sqrt(max(quad, 0))) + 1e-7
        let m = Float(media)
        let entrada = try MLMultiArray(shape: [1, NSNumber(value: Self.amostras)], dataType: .float32)
        entrada.withUnsafeMutableBufferPointer(ofType: Float.self) { p, st in
            let passo = st.last ?? 1
            for k in 0..<Self.amostras { p[k * passo] = k < n ? (audio[i0 + k] - m) / desvio : 0 }
        }
        let r = try modelo.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: entrada)]))
        guard let lp = r.featureValue(for: "logprobs")?.multiArrayValue, lp.shape.count == 3 else {
            throw ErroApp("O alinhador não devolveu a saída esperada.")
        }
        let T = lp.shape[1].intValue, V = lp.shape[2].intValue
        let st = lp.strides.map { $0.intValue }
        var out = Array(repeating: Array(repeating: Float(0), count: V), count: T)
        if lp.dataType == .float16 {
            lp.withUnsafeBufferPointer(ofType: Float16.self) { p in
                for t in 0..<T { for v in 0..<V { out[t][v] = Float(p[t * st[1] + v * st[2]]) } }
            }
        } else {
            lp.withUnsafeBufferPointer(ofType: Float.self) { p in
                for t in 0..<T { for v in 0..<V { out[t][v] = p[t * st[1] + v * st[2]] } }
            }
        }
        return out
    }

    // MARK: alinhamento

    private func letras(_ p: String) -> [Int] {
        p.lowercased().precomposedStringWithCanonicalMapping.compactMap { vocab[$0] }
    }

    /// CTC forçado: para cada símbolo do alvo, (quadro inicial, final+1) ou (-1, -1).
    static func viterbi(_ e: ArraySlice<[Float]>, alvo: [Int], branco: Int) -> [(Int, Int)] {
        let T = e.count, L = alvo.count, S = 2 * L + 1
        let base = e.startIndex
        var rot = Array(repeating: branco, count: S)
        for j in 0..<L { rot[2 * j + 1] = alvo[j] }
        var pode2 = Array(repeating: false, count: S)
        if S > 3 { for s in stride(from: 3, to: S, by: 2) { pode2[s] = rot[s] != rot[s - 2] } }
        let neg: Float = -1e30
        var a = Array(repeating: neg, count: S)
        a[0] = e[base][branco]
        if S > 1 { a[1] = e[base][rot[1]] }
        var volta = [UInt8](repeating: 0, count: T * S)
        var novo = Array(repeating: neg, count: S)
        if T > 1 {
            for t in 1..<T {
                let linha = e[base + t]
                for s in 0..<S {
                    let f0 = a[s]
                    let f1 = s >= 1 ? a[s - 1] : neg
                    let f2 = pode2[s] ? a[s - 2] : neg
                    var m = f0, k: UInt8 = 0
                    if f1 > m { m = f1; k = 1 }
                    if f2 > m { m = f2; k = 2 }
                    volta[t * S + s] = k
                    novo[s] = m + linha[rot[s]]
                }
                swap(&a, &novo)
            }
        }
        var s = (S == 1 || a[S - 1] >= a[S - 2]) ? S - 1 : S - 2
        var estados = Array(repeating: 0, count: T)
        var t = T - 1
        while t >= 0 {
            estados[t] = s
            s -= Int(volta[t * S + s])
            t -= 1
        }
        var spans = Array(repeating: (-1, -1), count: L)
        for (t, s) in estados.enumerated() where s % 2 == 1 {
            let j = s / 2
            if spans[j].0 < 0 { spans[j].0 = t }
            spans[j].1 = t + 1
        }
        return spans
    }

    /// Grupos de ~20 s pelos tempos do CrisperWhisper, cortados no maior silêncio dos últimos 8 s.
    private static func grupos(_ idx: [Int], _ w: [PalavraTempo], alvo: Double = 20) -> [[Int]] {
        var gs: [[Int]] = []
        var k = 0
        while k < idx.count {
            let ini = w[idx[k]].i ?? 0
            var j = k
            while j < idx.count && (w[idx[j]].i ?? 0) - ini <= alvo { j += 1 }
            if j < idx.count {
                var melhor = -1.0, corte = j
                for m in (k + 1)..<max(k + 1, j) {
                    if (w[idx[m]].i ?? 0) - ini < alvo - 8 { continue }
                    let gap = (w[idx[m]].i ?? 0) - (w[idx[m - 1]].f ?? 0)
                    if gap > melhor { melhor = gap; corte = m }
                }
                j = max(corte, k + 1)
            }
            gs.append(Array(idx[k..<j]))
            k = j
        }
        return gs
    }

    /// Tempos novos para as palavras. Sons marcados ([UH]…) e palavras sem letra ficam com o espaço
    /// entre as vizinhas alinhadas. Grupo que não cabe (texto demais para o áudio) mantém os tempos antigos.
    func alinhar(_ w: [PalavraTempo], audio: [Float], progresso: (Double) -> Void) throws -> [PalavraTempo] {
        let dur = Double(audio.count) / 16000
        let e = try emissoes(audio) { progresso($0 * 0.8) }
        let T = e.count
        let idx = w.indices.filter { k in
            w[k].i != nil && w[k].f != nil && !w[k].p.trimmingCharacters(in: .whitespaces).hasPrefix("[") && !letras(w[k].p).isEmpty
        }
        var novos: [Int: (Double, Double)] = [:]
        var fimAnt: Double?
        let gs = Self.grupos(idx, w)
        for (n, g) in gs.enumerated() {
            try Task.checkCancellation()
            progresso(0.8 + 0.2 * Double(n) / Double(max(gs.count, 1)))
            let a = fimAnt ?? max(0, (w[g[0]].i ?? 0) - 1.5)
            let b = min(dur, max((w[g[g.count - 1]].f ?? 0) + 1.5, a + 1))
            let q0 = max(0, Int(a / Self.quadro)), q1 = min(T, Int((b / Self.quadro).rounded(.up)))
            var alvo: [Int] = [], dono: [Int] = []
            for (m, k) in g.enumerated() {
                if m > 0 { alvo.append(separador); dono.append(-1) }
                for c in letras(w[k].p) { alvo.append(c); dono.append(k) }
            }
            guard q1 - q0 >= alvo.count + 1 else { continue }
            let spans = Self.viterbi(e[q0..<q1], alvo: alvo, branco: branco)
            for (sp, k) in zip(spans, dono) where k >= 0 && sp.0 >= 0 {
                let i0 = Double(q0 + sp.0) * Self.quadro, f0 = Double(q0 + sp.1) * Self.quadro
                if let x = novos[k] { novos[k] = (min(x.0, i0), max(x.1, f0)) } else { novos[k] = (i0, f0) }
            }
            if let ult = g.last, let x = novos[ult] { fimAnt = x.1 }
        }
        var out = w
        for (k, x) in novos {
            out[k].i = (x.0 * 1000).rounded() / 1000
            out[k].f = (x.1 * 1000).rounded() / 1000
        }
        for k in out.indices where novos[k] == nil {
            var ant = 0.0, prox = dur
            if let j = stride(from: k - 1, through: 0, by: -1).first(where: { novos[$0] != nil }) { ant = out[j].f ?? 0 }
            if let j = (k + 1..<out.count).first(where: { novos[$0] != nil }) { prox = out[j].i ?? dur }
            out[k].i = ant; out[k].f = max(ant, prox)
        }
        progresso(1)
        return out
    }
}
