import Foundation
import CoreML

// MARK: - modelo no iPhone

/// O Chatterbox (clonagem de voz) no iPhone. Fica em "No meu iPhone › Estúdio › Chatterbox";
/// se faltar algo, é baixado de cdn.frx9.com/modelos/chatterbox/ (mesmo esquema do CrisperWhisper).
/// O T3 chega como T3.mlpackage e o iPhone compila na primeira vez (vira T3.mlmodelc).
enum ModeloChatterbox {
    static let base = URL(string: "https://cdn.frx9.com/modelos/chatterbox/")!
    static let tamanhoAproximado: Int64 = 1_650_000_000
    static let arquivosFixos = ["config.json", "tokenizer.json", "texto.f16", "texto_pos.f16", "fala.f16",
                                "fala_pos.f16", "emocao.f16", "conditional_decoder.onnx", "conditional_decoder.onnx_data"]

    static var pasta: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chatterbox", isDirectory: true)
    }
    static var compilado: URL { pasta.appendingPathComponent("T3.mlmodelc", isDirectory: true) }
    static var pacote: URL { pasta.appendingPathComponent("T3.mlpackage", isDirectory: true) }

    static var temCompilado: Bool {
        FileManager.default.fileExists(atPath: compilado.appendingPathComponent("coremldata.bin").path)
    }

    static var pronto: Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: pasta.appendingPathComponent(".incompleto").path)
            && (temCompilado || fm.fileExists(atPath: pacote.appendingPathComponent("Manifest.json").path))
            && arquivosFixos.allSatisfy { fm.fileExists(atPath: pasta.appendingPathComponent($0).path) }
    }

    static func tamanhoEmDisco() -> Int64 { ModeloCrisper.tamanho(pasta) }
    static func apagar() { try? FileManager.default.removeItem(at: pasta) }

    /// Compila o T3.mlpackage (só na primeira vez) e apaga o pacote, que não é mais usado.
    static func compilarSePreciso() async throws -> URL {
        if temCompilado { return compilado }
        guard FileManager.default.fileExists(atPath: pacote.path) else {
            throw ErroApp("O T3 do Chatterbox não está no iPhone. Toque em Baixar.")
        }
        let tmp = try await MLModel.compileModel(at: pacote)
        try? FileManager.default.removeItem(at: compilado)
        try FileManager.default.moveItem(at: tmp, to: compilado)
        try? FileManager.default.removeItem(at: pacote)
        return compilado
    }
}

/// Download do Chatterbox em andamento (sobrevive a sair e voltar da tela).
@MainActor @Observable
final class BaixaChatterbox {
    static let shared = BaixaChatterbox()
    var progresso: Double?
    var mensagem: String?
    private var tarefa: Task<Void, Never>?
    var baixando: Bool { tarefa != nil }

    func iniciar() {
        guard tarefa == nil else { return }
        progresso = 0; mensagem = "Baixando"
        tarefa = Task {
            do {
                let aviso: @Sendable (Double, String) -> Void = { p, msg in
                    Task { @MainActor in
                        guard BaixaChatterbox.shared.tarefa != nil else { return }
                        BaixaChatterbox.shared.progresso = p; BaixaChatterbox.shared.mensagem = msg
                    }
                }
                // com o T3 já compilado, o pacote não precisa vir de novo
                if !ModeloChatterbox.pronto {
                    try await ModeloCrisper.baixar(de: ModeloChatterbox.base, para: ModeloChatterbox.pasta,
                                                   nome: "o Chatterbox", pular: ModeloChatterbox.temCompilado ? "T3.mlpackage/" : nil,
                                                   progresso: aviso)
                }
                mensagem = "Chatterbox pronto."
            } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                mensagem = "Download pausado. Toque em Baixar para continuar de onde parou."
            } catch {
                mensagem = "Falhou: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
            progresso = nil
            tarefa = nil
        }
    }

    func cancelar() { tarefa?.cancel() }
}

// MARK: - voz

/// A voz já processada no GT-PC (rodar-iphone.sh → voz-gabriel.json).
struct VozChatterbox: Decodable {
    struct Matriz: Decodable { var linhas: Int; var colunas: Int; var valores: [Float] }
    struct Conferencia: Decodable {
        var texto: String
        var exageracao: Float
        var cfg: Float
        var tokens_gulosos: [Int]
        var logits_inicio: [Float]
    }
    var versao: Int
    var origem: String?
    var modelo: String?
    var cond: [Float]                 // 33 x 1024
    var prompt_token: [Int64]
    var xvector: [Float]
    var prompt_feat: Matriz
    var conferencia: Conferencia?

    static var pasta: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chatterbox-vozes", isDirectory: true)
    }

    /// Vozes em "Estúdio › Chatterbox-vozes" e soltas na raiz do app (voz-*.json).
    static func disponiveis() -> [URL] {
        let fm = FileManager.default
        let raiz = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var r: [URL] = []
        for p in [pasta, raiz] {
            let itens = (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil)) ?? []
            r += itens.filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.lowercased().hasPrefix("voz") }
        }
        return r.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func ler(_ u: URL) throws -> VozChatterbox {
        let v = try JSONDecoder().decode(VozChatterbox.self, from: Data(contentsOf: u))
        guard v.cond.count == 33 * 1024, v.prompt_feat.valores.count == v.prompt_feat.linhas * v.prompt_feat.colunas,
              !v.prompt_token.isEmpty, !v.xvector.isEmpty else {
            throw ErroApp("\(u.lastPathComponent) não é uma voz do Chatterbox válida.")
        }
        return v
    }
}

// MARK: - motor

/// Gera fala com a voz clonada: T3 (Core ML, com o cache dentro do modelo) escolhe os tokens de fala,
/// e o decodificador (ONNX, CPU) transforma em áudio de 24 kHz. Mesmo algoritmo do gerador de
/// referência em testes/clonagem-voz/preparar_iphone.py (conferido contra o original).
final class MotorChatterbox: @unchecked Sendable {
    struct Config: Decodable {
        struct Amostragem: Decodable {
            var cfg: Float; var exageracao: Float; var temperatura: Float
            var repeticao: Float; var min_p: Float; var max_tokens: Int
        }
        struct Decodificador: Decodable { var arquivo: String; var entradas: [String] }
        struct TesteTok: Decodable { var texto: String; var tokens: [Int] }
        var versao: Int
        var modelo: String?
        var dim: Int
        var max_ctx: Int
        var linhas_cond: Int
        var texto_inicio: Int
        var texto_fim: Int
        var fala_inicio: Int
        var fala_fim: Int
        var fala_validos: Int
        var amostragem: Amostragem
        var decodificador: Decodificador
        var testes_tokenizer: [TesteTok]
    }

    struct Ajustes: Sendable {
        var cfg: Float = 0.5
        var exageracao: Float = 0.3
        var temperatura: Float = 0.8
        var repeticao: Float = 1.2
        var minP: Float = 0.05
        var semente: UInt64? = nil          // nil = escolhe sempre o mais provável (conferência)
        var maxTokens: Int? = nil
    }

    struct Resultado: Sendable {
        var audio: [Float]
        var tokens: [Int]
        var segundosT3: Double
        var segundosDecodificador: Double
        var trechos: Int
        var cortadoPorLimite: Bool
        var primeirosLogits: [Float]
        var duracao: Double { Double(audio.count) / 24000 }
    }

    let config: Config
    let tokenizador: TokenizadorChatterbox
    private let t3: MLModel
    private let texto: Data, textoPos: Data, fala: Data, falaPos: Data, emocao: Data
    private var ort: OpaquePointer?

    init(onde: CrisperModelo.Onde, compilado: URL) throws {
        let p = ModeloChatterbox.pasta
        config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: p.appendingPathComponent("config.json")))
        tokenizador = try TokenizadorChatterbox(arquivo: p.appendingPathComponent("tokenizer.json"))
        func tabela(_ n: String) throws -> Data { try Data(contentsOf: p.appendingPathComponent(n), options: .alwaysMapped) }
        texto = try tabela("texto.f16"); textoPos = try tabela("texto_pos.f16")
        fala = try tabela("fala.f16"); falaPos = try tabela("fala_pos.f16"); emocao = try tabela("emocao.f16")
        let c = MLModelConfiguration()
        c.computeUnits = onde.unidades
        t3 = try MLModel(contentsOf: compilado, configuration: c)
    }

    deinit { if let o = ort { cb_ort_fechar(o) } }

    /// Confere o tokenizador contra as frases do config.json. Retorna (iguais, total, primeira diferença).
    func conferirTokenizador() -> (Int, Int, String?) {
        var iguais = 0
        var dif: String?
        for t in config.testes_tokenizer {
            let meu = [config.texto_inicio] + tokenizador.codificar(t.texto) + [config.texto_fim]
            if meu == t.tokens { iguais += 1 }
            else if dif == nil {
                let lim = min(meu.count, t.tokens.count)
                let k = (0..<lim).first { meu[$0] != t.tokens[$0] } ?? lim
                dif = "“\(t.texto.prefix(30))…”: posição \(k), iPhone \(meu.dropFirst(k).prefix(5).map(String.init).joined(separator: " ")) x original \(t.tokens.dropFirst(k).prefix(5).map(String.init).joined(separator: " "))"
            }
        }
        return (iguais, config.testes_tokenizer.count, dif)
    }

    // MARK: tabelas

    private func linha(_ d: Data, _ i: Int, em destino: UnsafeMutablePointer<Float16>, somar: Bool = false) {
        let D = config.dim
        d.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float16.self).baseAddress! + i * D
            if somar {
                for k in 0..<D { destino[k] = Float16(Float(destino[k]) + Float(src[k])) }
            } else {
                destino.update(from: src, count: D)
            }
        }
    }

    // MARK: geração

    /// Divide textos longos em trechos de até ~250 letras, nas pontuações.
    static func trechos(_ t: String, maximo: Int = 250) -> [String] {
        let limpo = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limpo.count > maximo else { return [limpo] }
        var frases: [String] = []
        var atual = ""
        for ch in limpo {
            atual.append(ch)
            if ".!?;\n".contains(ch) {
                let f = atual.trimmingCharacters(in: .whitespacesAndNewlines)
                if !f.isEmpty { frases.append(f) }
                atual = ""
            }
        }
        let resto = atual.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resto.isEmpty { frases.append(resto) }
        var saida: [String] = []
        var bloco = ""
        for f in frases {
            if bloco.isEmpty { bloco = f }
            else if bloco.count + 1 + f.count <= maximo { bloco += " " + f }
            else { saida.append(bloco); bloco = f }
        }
        if !bloco.isEmpty { saida.append(bloco) }
        // frase sozinha acima do limite: corta nas vírgulas ou espaços
        return saida.flatMap { b -> [String] in
            guard b.count > maximo else { return [b] }
            var r: [String] = []
            var cur = ""
            for palavra in b.split(separator: " ") {
                if cur.count + 1 + palavra.count > maximo, !cur.isEmpty { r.append(cur); cur = String(palavra) }
                else { cur = cur.isEmpty ? String(palavra) : cur + " " + palavra }
            }
            if !cur.isEmpty { r.append(cur) }
            return r
        }
    }

    func gerar(_ textoCompleto: String, voz: VozChatterbox, ajustes a: Ajustes,
               progresso: @escaping (String) -> Void) throws -> Resultado {
        let partes = Self.trechos(textoCompleto)
        var audio: [Float] = []
        var todos: [Int] = []
        var tT3 = 0.0, tDec = 0.0
        var limite = false
        var primeiros: [Float] = []
        var rng = SorteioCB(a.semente ?? 0)
        for (n, parte) in partes.enumerated() {
            try Task.checkCancellation()
            let rotulo = partes.count > 1 ? "trecho \(n + 1) de \(partes.count): " : ""
            let t0 = Date()
            let (toks, cortou, lg) = try tokensDeFala(parte, voz: voz, ajustes: a, rng: &rng) { k in
                progresso(rotulo + "\(k) tokens de fala")
            }
            tT3 += Date().timeIntervalSince(t0)
            if n == 0 { primeiros = lg }
            limite = limite || cortou
            todos += toks
            progresso(rotulo + "transformando em áudio")
            let t1 = Date()
            let w = try decodificar(toks, voz: voz)
            tDec += Date().timeIntervalSince(t1)
            if !audio.isEmpty { audio += [Float](repeating: 0, count: 6000) }     // 0,25 s entre trechos
            audio += w
        }
        return Resultado(audio: audio, tokens: todos, segundosT3: tT3, segundosDecodificador: tDec,
                         trechos: partes.count, cortadoPorLimite: limite, primeirosLogits: primeiros)
    }

    private func tokensDeFala(_ txt: String, voz: VozChatterbox, ajustes a: Ajustes, rng: inout SorteioCB,
                              aviso: (Int) -> Void) throws -> ([Int], Bool, [Float]) {
        let D = config.dim
        let tt = [config.texto_inicio] + tokenizador.codificar(txt) + [config.texto_fim]
        let nc = config.linhas_cond + 1
        let q = nc + tt.count + 2
        guard q + 8 < config.max_ctx else { throw ErroApp("Texto longo demais para um trecho.") }
        // limite contra "disparada": ~25 tokens por segundo, ~15 letras por segundo de fala
        let esperado = Int(Double(txt.count) / 15 * 25) + 10
        var maximo = min(config.amostragem.max_tokens, 4 * esperado + 64, config.max_ctx - q - 1)
        if let m = a.maxTokens { maximo = min(maximo, m) }

        // prefill: [cond | texto | início | início], linha 1 sem texto (CFG)
        let emb = try MLMultiArray(shape: [2, NSNumber(value: q), NSNumber(value: D)], dataType: .float16)
        try Self.exigirContinuo(emb)
        let base = emb.dataPointer.bindMemory(to: Float16.self, capacity: 2 * q * D)
        for b in 0..<2 {
            let lin = base + b * q * D
            for r in 0..<config.linhas_cond {
                for k in 0..<D { lin[r * D + k] = Float16(voz.cond[r * D + k]) }
            }
            emocao.withUnsafeBytes { raw in
                let w = raw.bindMemory(to: Float16.self).baseAddress!
                let dst = lin + config.linhas_cond * D
                for k in 0..<D { dst[k] = Float16(a.exageracao * Float(w[k])) }
            }
            for (j, t) in tt.enumerated() {
                let dst = lin + (nc + j) * D
                if b == 0 { linha(texto, t, em: dst); linha(textoPos, j, em: dst, somar: true) }
                else { linha(textoPos, j, em: dst) }
            }
            for j in 0..<2 {
                let dst = lin + (nc + tt.count + j) * D
                linha(fala, config.fala_inicio, em: dst); linha(falaPos, 0, em: dst, somar: true)
            }
        }
        let estado = t3.makeState()
        var fim = q
        var lg = try passo(emb, q: q, fim: fim, estado: estado)
        var gerados: Set<Int> = [config.fala_inicio]
        var saida: [Int] = []
        var primeiros: [Float] = []
        var cortou = true
        let V = lg.count / 2
        var l = [Float](repeating: 0, count: V)
        let um = try MLMultiArray(shape: [2, 1, NSNumber(value: D)], dataType: .float16)
        try Self.exigirContinuo(um)
        let pu = um.dataPointer.bindMemory(to: Float16.self, capacity: 2 * D)
        for i in 0..<maximo {
            try Task.checkCancellation()
            for k in 0..<V { l[k] = lg[k] + a.cfg * (lg[k] - lg[V + k]) }
            if i == 0 { primeiros = Array(l.prefix(16)) }
            for g in gerados { l[g] = l[g] < 0 ? l[g] * a.repeticao : l[g] / a.repeticao }
            let tok: Int
            if a.semente == nil {
                tok = l.indices.max { l[$0] < l[$1] } ?? 0
            } else {
                tok = Self.sortear(&l, temperatura: a.temperatura, minP: a.minP, rng: &rng)
            }
            if tok == config.fala_fim { cortou = false; break }
            saida.append(tok); gerados.insert(tok)
            if i % 25 == 0 { aviso(saida.count) }
            linha(fala, tok, em: pu); linha(falaPos, i + 1, em: pu, somar: true)
            (pu + D).update(from: pu, count: D)
            fim += 1
            lg = try passo(um, q: 1, fim: fim, estado: estado)
        }
        return (saida, cortou, primeiros)
    }

    /// Uma chamada do T3: devolve os logits [linha 0 ..., linha 1 ...] em Float.
    private func passo(_ emb: MLMultiArray, q: Int, fim: Int, estado: MLState) throws -> [Float] {
        let m = try MLMultiArray(shape: [1, 1, NSNumber(value: q), NSNumber(value: fim)], dataType: .float16)
        let st = m.strides.map(\.intValue)
        let pm = m.dataPointer.bindMemory(to: Float16.self, capacity: max(q * st[2], 1))
        let ini = fim - q
        for r in 0..<q {
            for c in 0..<fim { pm[r * st[2] + c * st[3]] = c <= ini + r ? 0 : -10000 }
        }
        let entrada = try MLDictionaryFeatureProvider(dictionary: ["embeds": emb, "mascara": m])
        let s = try t3.prediction(from: entrada, using: estado)
        guard let o = s.featureValue(for: "logits")?.multiArrayValue, o.shape.count == 2 else {
            throw ErroApp("O T3 não devolveu os logits.")
        }
        let V = o.shape[1].intValue
        let s0 = o.strides[0].intValue, s1 = o.strides[1].intValue
        var r = [Float](repeating: 0, count: 2 * V)
        switch o.dataType {
        case .float16:
            let p = o.dataPointer.bindMemory(to: Float16.self, capacity: s0 * 2)
            for b in 0..<2 { for k in 0..<V { r[b * V + k] = Float(p[b * s0 + k * s1]) } }
        case .float32:
            let p = o.dataPointer.bindMemory(to: Float.self, capacity: s0 * 2)
            for b in 0..<2 { for k in 0..<V { r[b * V + k] = p[b * s0 + k * s1] } }
        default:
            throw ErroApp("Tipo inesperado nos logits do T3.")
        }
        if r.contains(where: { !$0.isFinite }) { throw ErroApp("O T3 devolveu NaN (precisão do Core ML).") }
        return r
    }

    /// As tabelas são copiadas linha a linha: o vetor precisa estar contínuo na memória.
    private static func exigirContinuo(_ a: MLMultiArray) throws {
        let forma = a.shape.map(\.intValue), st = a.strides.map(\.intValue)
        var esperado = 1
        for k in stride(from: forma.count - 1, through: 0, by: -1) {
            guard st[k] == esperado || forma[k] == 1 else { throw ErroApp("Vetor do Core ML com memória não contínua.") }
            esperado *= forma[k]
        }
    }

    /// Temperatura, min-p e sorteio (igual ao original).
    static func sortear(_ l: inout [Float], temperatura: Float, minP: Float, rng: inout SorteioCB) -> Int {
        let t = max(temperatura, 1e-4)
        var mx = -Float.infinity
        for k in l.indices { l[k] /= t; if l[k] > mx { mx = l[k] } }
        var soma: Float = 0
        for k in l.indices { l[k] = exp(l[k] - mx); soma += l[k] }
        let corte = minP * (1 / soma)          // prob máxima = 1/soma (o maior vira exp(0) = 1)
        var tot: Double = 0
        for k in l.indices {
            let p = l[k] / soma
            if p < corte { l[k] = 0 } else { tot += Double(l[k]) }
        }
        var alvo = rng.proximo() * tot
        for k in l.indices where l[k] > 0 {
            alvo -= Double(l[k])
            if alvo <= 0 { return k }
        }
        return l.lastIndex { $0 > 0 } ?? 0
    }

    // MARK: decodificador

    private func decodificar(_ toks: [Int], voz: VozChatterbox) throws -> [Float] {
        if ort == nil {
            let arq = ModeloChatterbox.pasta.appendingPathComponent(config.decodificador.arquivo).path
            ort = cb_ort_abrir(arq)
            if let e = ort.map({ String(cString: cb_ort_erro($0)) }), !e.isEmpty {
                cb_ort_fechar(ort); ort = nil
                throw ErroApp("O decodificador não abriu: \(e)")
            }
        }
        let validos = toks.filter { $0 < config.fala_validos }
        guard !validos.isEmpty else { return [] }
        let entrada = voz.prompt_token + validos.map { Int64($0) }
        let nomes = config.decodificador.entradas
        func nome(_ chave: String, _ padrao: String) -> String { nomes.first { $0.contains(chave) } ?? padrao }
        var saida: UnsafeMutablePointer<Float>?
        var n: Int64 = 0
        let r = entrada.withUnsafeBufferPointer { pt in
            voz.xvector.withUnsafeBufferPointer { px in
                voz.prompt_feat.valores.withUnsafeBufferPointer { pf in
                    cb_ort_decodificar(ort, nome("token", "speech_tokens"), pt.baseAddress, Int64(pt.count),
                                       nome("embedding", "speaker_embeddings"), px.baseAddress, Int64(px.count),
                                       nome("feat", "speaker_features"), pf.baseAddress,
                                       Int64(voz.prompt_feat.linhas), Int64(voz.prompt_feat.colunas), &saida, &n)
                }
            }
        }
        guard r == 0, let s = saida else {
            throw ErroApp("O decodificador falhou: \(String(cString: cb_ort_erro(ort)))")
        }
        defer { cb_ort_liberar(s) }
        var w = Array(UnsafeBufferPointer(start: s, count: Int(n)))
        // como o original: 20 ms em silêncio e 20 ms subindo, para não vazar a referência
        let nt = 480
        for k in 0..<min(2 * nt, w.count) {
            w[k] *= k < nt ? 0 : Float((cos(Double.pi * (1 - Double(k - nt) / Double(nt - 1))) + 1) / 2)
        }
        return w
    }
}

/// SplitMix64: sorteio repetível pela semente.
struct SorteioCB {
    private var s: UInt64
    init(_ semente: UInt64) { s = semente &+ 0x9E3779B97F4A7C15 }
    mutating func proximo() -> Double {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
