import Foundation
import CoreML

/// As três partes do CrisperWhisper convertidas para o iPhone (pasta com MelSpectrogram,
/// AudioEncoder e TextDecoder .mlmodelc) e a decodificação token a token, igual à do
/// pacote oficial: gulosa, com a lista de tokens suprimidos e a atenção para os tempos.
final class CrisperModelo: @unchecked Sendable {
    enum Onde: String, CaseIterable, Identifiable {
        case neural = "Neural Engine", gpu = "GPU", cpu = "Só processador"
        var id: String { rawValue }
        var unidades: MLComputeUnits {
            switch self {
            case .neural: return .cpuAndNeuralEngine
            case .gpu: return .cpuAndGPU
            case .cpu: return .cpuOnly
            }
        }
    }

    static let amostrasJanela = 480_000          // 30 s a 16 kHz
    static let quadrosEncoder = 1500

    private let mel: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    let posicoes: Int                            // tamanho do cache do decodificador (448)
    private let largura: Int                     // 5120 = 4 camadas × 1280
    let suprimidos: [Bool]                       // por id: nunca escolher

    /// Procura a pasta com os três modelos dentro de `raiz` (até 3 níveis).
    static func acharPasta(em raiz: URL) -> URL? {
        let fm = FileManager.default
        func tem(_ u: URL) -> Bool {
            ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
                fm.fileExists(atPath: u.appendingPathComponent($0 + ".mlmodelc").path)
            }
        }
        if tem(raiz) { return raiz }
        guard let e = fm.enumerator(at: raiz, includingPropertiesForKeys: [.isDirectoryKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let u as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if tem(u) { return u }
        }
        return nil
    }

    /// Procura um arquivo pelo nome dentro de `raiz` (até 3 níveis).
    static func acharArquivo(_ nome: String, em raiz: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: raiz.appendingPathComponent(nome).path) { return raiz.appendingPathComponent(nome) }
        guard let e = fm.enumerator(at: raiz, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let u as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if u.lastPathComponent == nome { return u }
        }
        return nil
    }

    init(pasta: URL, onde: Onde, suprimir: [Int], vocabulario: Int = 51897) throws {
        let cMel = MLModelConfiguration(); cMel.computeUnits = .cpuAndGPU
        let c = MLModelConfiguration(); c.computeUnits = onde.unidades
        mel = try MLModel(contentsOf: pasta.appendingPathComponent("MelSpectrogram.mlmodelc"), configuration: cMel)
        encoder = try MLModel(contentsOf: pasta.appendingPathComponent("AudioEncoder.mlmodelc"), configuration: c)
        decoder = try MLModel(contentsOf: pasta.appendingPathComponent("TextDecoder.mlmodelc"), configuration: c)
        guard let kc = decoder.modelDescription.inputDescriptionsByName["key_cache"]?.multiArrayConstraint else {
            throw ErroApp("O TextDecoder não tem a entrada key_cache: não é o modelo esperado.")
        }
        let forma = kc.shape.map { $0.intValue }
        guard forma.count == 4 else { throw ErroApp("Formato inesperado do cache do decodificador: \(forma)") }
        largura = forma[1]; posicoes = forma[3]
        var s = Array(repeating: false, count: vocabulario + 64)
        for t in suprimir where t >= 0 && t < s.count { s[t] = true }
        suprimidos = s
    }

    // MARK: áudio -> mel -> codificador

    /// Um trecho de até 30 s (16 kHz mono) -> (saída do codificador, mel [128][3000] para os tempos).
    func codificar(_ trecho: ArraySlice<Float>) throws -> (MLMultiArray, [[Float]]) {
        let audio = try MLMultiArray(shape: [NSNumber(value: Self.amostrasJanela)], dataType: .float16)
        audio.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in
            var k = 0
            for v in trecho { if k >= Self.amostrasJanela { break }; p[k] = Float16(v); k += 1 }
            while k < Self.amostrasJanela { p[k] = 0; k += 1 }
        }
        let m = try mel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)]))
        guard let melArr = m.featureValue(for: "melspectrogram_features")?.multiArrayValue else {
            throw ErroApp("O MelSpectrogram não devolveu o espectrograma.")
        }
        let e = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["melspectrogram_features": MLFeatureValue(multiArray: melArr)]))
        guard let emb = e.featureValue(for: "encoder_output_embeds")?.multiArrayValue else {
            throw ErroApp("O AudioEncoder não devolveu a saída esperada.")
        }
        try Self.exigirFloat16(melArr, "melspectrogram_features")
        // mel [1, 128, 1, 3000] -> [128][3000]
        let f = melArr.shape.map { $0.intValue }
        guard f.count == 4 else { throw ErroApp("Formato inesperado do mel: \(f)") }
        let nMel = f[1], nQ = f[3]
        var melMat = Array(repeating: Array(repeating: Float(0), count: nQ), count: nMel)
        melArr.withUnsafeBufferPointer(ofType: Float16.self) { p in
            let st = melArr.strides.map { $0.intValue }
            for c in 0..<nMel { for t in 0..<nQ { melMat[c][t] = Float(p[c * st[1] + t * st[3]]) } }
        }
        return (emb, melMat)
    }

    // MARK: decodificação

    /// Decodifica a partir de `prompt` até o fim do texto ou `maxNovos` tokens. `banirNoPrimeiro`:
    /// tokens proibidos só no primeiro passo (o reparo de alucinação do pacote oficial).
    /// Devolve os tokens gerados e, para cada um, a atenção (1500 quadros) que o escolheu.
    func decodificar(prompt: [Int], encoder emb: MLMultiArray, maxNovos: Int,
                     banirNoPrimeiro: Set<Int> = [], eot: Int) throws -> ([Int], [[Float]]) {
        guard maxNovos > 0 else { return ([], []) }
        let L = posicoes
        let kc = try MLMultiArray(shape: [1, NSNumber(value: largura), 1, NSNumber(value: L)], dataType: .float16)
        let vc = try MLMultiArray(shape: [1, NSNumber(value: largura), 1, NSNumber(value: L)], dataType: .float16)
        let mascaraAtual = try MLMultiArray(shape: [1, NSNumber(value: L)], dataType: .float16)
        let mascaraPad = try MLMultiArray(shape: [1, NSNumber(value: L)], dataType: .float16)
        for a in [kc, vc, mascaraAtual] {
            a.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in for i in 0..<p.count { p[i] = 0 } }
        }
        mascaraPad.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in for i in 0..<p.count { p[i] = -10000 } }
        let entrada = try MLMultiArray(shape: [1], dataType: .int32)
        let tamanho = try MLMultiArray(shape: [1], dataType: .int32)
        let embValor = MLFeatureValue(multiArray: emb)
        let kcSt = kc.strides.map { $0.intValue }
        let mSt = mascaraAtual.strides.map { $0.intValue }

        var seq = prompt
        var gerados: [Int] = []
        var atencao: [[Float]] = []
        var pos = 0
        while pos < L - 1 {
            entrada[0] = NSNumber(value: Int32(seq[pos]))
            tamanho[0] = NSNumber(value: Int32(pos))
            mascaraAtual.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in
                if pos > 0 { p[(pos - 1) * mSt[1]] = 0 }
                p[pos * mSt[1]] = 1
            }
            mascaraPad.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in p[pos * mSt[1]] = 0 }
            let saida = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: entrada),
                "cache_length": MLFeatureValue(multiArray: tamanho),
                "key_cache": MLFeatureValue(multiArray: kc),
                "value_cache": MLFeatureValue(multiArray: vc),
                "kv_cache_update_mask": MLFeatureValue(multiArray: mascaraAtual),
                "encoder_output_embeds": embValor,
                "decoder_key_padding_mask": MLFeatureValue(multiArray: mascaraPad),
            ]))
            guard let ku = saida.featureValue(for: "key_cache_updates")?.multiArrayValue,
                  let vu = saida.featureValue(for: "value_cache_updates")?.multiArrayValue,
                  let logits = saida.featureValue(for: "logits")?.multiArrayValue else {
                throw ErroApp("O TextDecoder não devolveu as saídas esperadas.")
            }
            if pos == 0 {
                try Self.exigirFloat16(ku, "key_cache_updates"); try Self.exigirFloat16(vu, "value_cache_updates")
                try Self.exigirFloat16(logits, "logits")
            }
            copiar(ku, para: kc, posicao: pos, estrides: kcSt)
            copiar(vu, para: vc, posicao: pos, estrides: kcSt)

            if pos >= prompt.count - 1 {
                let primeiro = gerados.isEmpty
                var melhor = -1
                var valor = -Float.infinity
                logits.withUnsafeBufferPointer(ofType: Float16.self) { p in
                    let st = logits.strides.map { $0.intValue }
                    let n = logits.shape.last!.intValue
                    let passo = st.last!
                    for t in 0..<n {
                        if t < suprimidos.count && suprimidos[t] { continue }
                        if primeiro && banirNoPrimeiro.contains(t) { continue }
                        let v = Float(p[t * passo])
                        if v > valor { valor = v; melhor = t }
                    }
                }
                if let al = saida.featureValue(for: "alignment_heads_weights")?.multiArrayValue, al.dataType == .float16 {
                    var linha = Array(repeating: Float(0), count: Self.quadrosEncoder)
                    al.withUnsafeBufferPointer(ofType: Float16.self) { p in
                        let st = al.strides.map { $0.intValue }
                        let n = min(Self.quadrosEncoder, al.shape.last!.intValue)
                        for f in 0..<n { linha[f] = Float(p[f * st.last!]) }
                    }
                    atencao.append(linha)
                }
                if melhor < 0 || melhor == eot || gerados.count >= maxNovos { break }
                gerados.append(melhor); seq.append(melhor)
            }
            pos += 1
        }
        return (gerados, Array(atencao.prefix(gerados.count)))
    }

    private static func exigirFloat16(_ a: MLMultiArray, _ nome: String) throws {
        guard a.dataType == .float16 else { throw ErroApp("A saída \(nome) do modelo veio num formato inesperado.") }
    }

    private func copiar(_ origem: MLMultiArray, para destino: MLMultiArray, posicao: Int, estrides st: [Int]) {
        let oSt = origem.strides.map { $0.intValue }
        origem.withUnsafeBufferPointer(ofType: Float16.self) { o in
            destino.withUnsafeMutableBufferPointer(ofType: Float16.self) { d, _ in
                for c in 0..<largura { d[c * st[1] + posicao * st[3]] = o[c * oSt[1]] }
            }
        }
    }
}
