import Foundation
import AVFoundation
import CoreML

/// Transcrição "verbatim" (tudo o que foi dito, com [UH], gaguejos e repetições) do CrisperWhisper,
/// seguindo o caminho longo do pacote oficial (`continuation_transcribe_with_word_timestamps`):
/// janelas de 30 s a cada 26 s, as últimas 12 palavras confirmadas como contexto da próxima janela,
/// descarte das palavras finais que a janela seguinte vai ouvir de novo, reparo de laços de repetição.
/// Também como no pacote: o recomeço com temperatura de um trecho que "desaba" (fala enchendo a janela
/// e quase nenhuma palavra) e a recuperação de um fim de texto precoce (o modelo para numa pausa e
/// deixa fala sem transcrever). Os dois quase nunca entram em ação.
final class CrisperTranscritor: @unchecked Sendable {
    struct Resultado {
        var texto: String
        var palavras: [PalavraTempo]
        var segundosAudio: Double
        var reparos: Int
        var recomecos = 0
        var fimRecuperado = 0
    }

    /// Muda quando a transcrição em si muda: transcrições guardadas de outra versão são refeitas.
    static let versao = 2
    static let janela = 30.0, passo = 26.0
    // recomeço com temperatura (fallback.py)
    static let temperaturas: [Float] = [0.4, 0.6, 0.8, 1.0]
    static let sorteiosPorTemperatura = 3
    // fim precoce (early_eot.py / EarlyEotConfig)
    static let fimDuvidoso: Float = 0.7, fimConfiante: Float = 0.9
    static let faltaNoUltimo = 2.0, faltaNosOutros = 4.0
    static let palavrasContexto = 12, descartar = 2, maxNovos = 256
    static let limiaresLaco: [(n: Int, reps: Int)] = [(1, 8), (2, 8), (3, 4), (4, 3), (5, 3)]

    let tok: CrisperTokenizador
    let modelo: CrisperModelo
    let idioma: Int

    init(pasta: URL, onde: CrisperModelo.Onde) throws {
        guard let arqTok = CrisperModelo.acharArquivo("tokenizer.json", em: pasta) else {
            throw ErroApp("Falta o tokenizer.json na pasta do CrisperWhisper.")
        }
        tok = try CrisperTokenizador(arquivo: arqTok)
        var suprimir: [Int] = []
        if let g = CrisperModelo.acharArquivo("generation_config.json", em: pasta),
           let d = try? Data(contentsOf: g),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let s = j["suppress_tokens"] as? [Int] {
            suprimir = s.filter { $0 >= 0 }
        } else {
            throw ErroApp("Falta o generation_config.json na pasta do CrisperWhisper (lista de tokens suprimidos).")
        }
        guard let pastaModelos = CrisperModelo.acharPasta(em: pasta) else {
            throw ErroApp("Não achei MelSpectrogram, AudioEncoder e TextDecoder (.mlmodelc) na pasta do CrisperWhisper.")
        }
        modelo = try CrisperModelo(pasta: pastaModelos, onde: onde, suprimir: suprimir)
        guard let pt = tok.id("<|pt|>") else { throw ErroApp("O dicionário não tem o português.") }
        idioma = pt
    }

    /// Prompt do modo verbatim (ou do "intended", o texto limpo, usado só como comparação), com ou sem
    /// contexto (igual ao `PromptBuilder` oficial).
    func prompt(contexto: String?, limpo: Bool = false) -> [Int] {
        var texto = (1...5).map { limpo ? "[intended_\($0)]" : "[verbatim_\($0)]" }.joined()
        if let c = contexto, !c.isEmpty { texto += " <ctx> \(c) <ectx>" }
        return tok.codificar(texto) + [tok.sot, idioma, tok.transcrever, tok.semTempos]
    }

    /// Primeiro laço de repetição (posição, n-grama), como o `find_token_loop` oficial.
    static func acharLaco(_ ids: [Int]) -> (Int, [Int])? {
        for i in 0..<ids.count {
            for (n, reps) in limiaresLaco {
                let precisa = n * reps
                if i + precisa > ids.count { continue }
                let g = Array(ids[i..<(i + n)])
                var ok = true
                for r in 1..<reps where Array(ids[(i + r * n)..<(i + (r + 1) * n)]) != g { ok = false; break }
                if ok { return (i, g) }
            }
        }
        return nil
    }

    /// Decodificação com o reparo de alucinação (volta ao começo do laço e proíbe o token que o iniciou).
    private func decodificarComReparo(_ prompt: [Int], _ emb: MLMultiArray, reparos: inout Int) throws -> CrisperModelo.Decodificado {
        var d = try modelo.decodificar(prompt: prompt, encoder: emb, maxNovos: Self.maxNovos, eot: tok.eot)
        for _ in 1...3 {
            guard let laco = Self.acharLaco(d.ids) else { break }
            let inicio = laco.0, g = laco.1
            reparos += 1
            let corte = inicio + g.count
            let mantidos = Array(d.ids.prefix(corte))
            let attMantida = Array(d.atencao.prefix(corte))
            let resta = Self.maxNovos - mantidos.count
            if resta <= 0 { d = .init(ids: mantidos, atencao: attMantida, probFim: nil); break }
            let cauda = try modelo.decodificar(prompt: prompt + mantidos, encoder: emb, maxNovos: resta,
                                               banirNoPrimeiro: [g[0]], eot: tok.eot)
            d = .init(ids: mantidos + cauda.ids, atencao: attMantida + cauda.atencao, probFim: cauda.probFim)
        }
        return d
    }

    /// Quantas palavras um trecho decodificado tem (sem as marcas do prompt), como `word_count` oficial.
    func contarPalavras(_ ids: [Int]) -> Int {
        var t = tok.decodificar(ids, pularEspeciais: true)
        for padrao in [#"\[verbatim_\d+\]"#, #"\[intended_\d+\]"#, #"<ctx>.*?<ectx>"#] {
            t = t.replacingOccurrences(of: padrao, with: "", options: .regularExpression)
        }
        return t.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Segundos de fala na janela depois de `inicio` (portão de energia do mel: 20% entre os
    /// percentis 10 e 95), como `speech_active_seconds` / `_speech_active_after` oficiais.
    static func falaAtiva(_ mel: [[Float]], depoisDe inicio: Double = 0) -> Double {
        guard let nQ = mel.first?.count, nQ > 0 else { return 0 }
        var energia = Array(repeating: Float(0), count: nQ)
        for linha in mel { for q in 0..<nQ { energia[q] += linha[q] } }
        let nMel = Float(mel.count)
        for q in 0..<nQ { energia[q] /= nMel }
        let ord = energia.sorted()
        func percentil(_ x: Double) -> Float {
            let pos = x / 100 * Double(nQ - 1)
            let a = Int(pos), b = min(a + 1, nQ - 1)
            return ord[a] + (ord[b] - ord[a]) * Float(pos - Double(a))
        }
        let piso = percentil(10), pico = percentil(95)
        if pico - piso < 1e-3 { return 0 }
        let limiar = piso + 0.2 * (pico - piso)
        let de = max(Int(inicio / 0.01), 0)
        if de >= nQ { return 0 }
        var n = 0
        for q in de..<nQ where energia[q] > limiar { n += 1 }
        return Double(n) * 0.01
    }

    /// Fala enchendo a janela (≥ 5 s) e menos de 0,5 palavra por segundo dela.
    static func desabou(_ palavras: Int, _ mel: [[Float]]) -> Bool {
        let s = falaAtiva(mel)
        return s >= 5 && Double(palavras) < 0.5 * s
    }

    /// Recomeço com temperatura (fallback.py): só se a janela "desabou" e o modo limpo confirma que
    /// havia bem mais o que dizer; tenta 0,4 / 0,6 / 0,8 / 1,0 com 3 sorteios cada e fica com o primeiro
    /// que cobre a fala (ou o que tiver mais palavras).
    private func recomecoComTemperatura(_ base: CrisperModelo.Decodificado, prompt p: [Int], irmao: [Int],
                                        emb: MLMultiArray, mel: [[Float]], recomecos: inout Int) throws -> CrisperModelo.Decodificado {
        let n0 = contarPalavras(base.ids)
        guard Self.desabou(n0, mel) else { return base }
        let ref = try modelo.decodificar(prompt: irmao, encoder: emb, maxNovos: Self.maxNovos, eot: tok.eot)
        let nRef = contarPalavras(ref.ids)
        guard nRef >= 8 && Double(n0) < 0.5 * Double(nRef) else { return base }   // o modo limpo também saiu curto
        var melhor = base, nMelhor = n0, sorteada = false
        var semente: UInt64 = 0
        fora: for temp in Self.temperaturas {
            for _ in 0..<Self.sorteiosPorTemperatura {
                try Task.checkCancellation()
                let d = try modelo.decodificar(prompt: p, encoder: emb, maxNovos: Self.maxNovos, eot: tok.eot,
                                               temperatura: temp, semente: semente)
                semente += 1
                if Self.acharLaco(d.ids) != nil { continue }
                let n = contarPalavras(d.ids)
                if n > nMelhor { melhor = d; nMelhor = n; sorteada = true }
                if !Self.desabou(n, mel) { melhor = d; sorteada = true; break fora }
            }
        }
        if sorteada { recomecos += 1 }
        return sorteada ? melhor : base
    }

    /// Recuperação de fim precoce (early_eot.py): sobra fala depois da última palavra, o modelo parou
    /// sem convicção (P(fim) < 0,7) e, forçado a seguir, termina com convicção (≥ 0,9).
    private func recuperarFimPrecoce(_ d: CrisperModelo.Decodificado, locais: [PalavraTempo], prompt p: [Int],
                                     emb: MLMultiArray, mel: [[Float]], ultimo: Bool) throws -> CrisperModelo.Decodificado? {
        guard let fimUltima = locais.compactMap({ $0.f }).max() else { return nil }
        let falta = ultimo ? Self.faltaNoUltimo : Self.faltaNosOutros
        guard Self.falaAtiva(mel, depoisDe: fimUltima) >= falta else { return nil }
        guard let pf = d.probFim, pf < Self.fimDuvidoso else { return nil }
        let ext = try modelo.decodificar(prompt: p, encoder: emb, maxNovos: Self.maxNovos, eot: tok.eot,
                                         semFimAntes: d.ids.count + 1)
        guard let pe = ext.probFim, pe >= Self.fimConfiante, ext.ids.count > d.ids.count else { return nil }
        return ext
    }

    func transcrever(_ audio: [Float], progresso: (Double, String) -> Void) throws -> Resultado {
        let taxa = 16000.0
        let tamJanela = Int(Self.janela * taxa), tamPasso = Int(Self.passo * taxa)
        var inicios: [Int] = []
        if audio.count <= tamJanela { inicios = [0] } else {
            var s = 0
            while s < audio.count {
                inicios.append(s)
                if s + tamJanela >= audio.count { break }
                s += tamPasso
            }
        }
        var confirmadas: [String] = []
        var globais: [PalavraTempo] = []
        var reparos = 0, recomecos = 0, fimRecuperado = 0
        for (k, ini) in inicios.enumerated() {
            try Task.checkCancellation()
            let ultimo = k == inicios.count - 1
            let fimAmostra = min(ini + tamJanela, audio.count)
            let inicioSeg = Double(k) * Self.passo
            progresso(Double(k) / Double(inicios.count), "Trecho \(k + 1) de \(inicios.count)")
            let ctx = k == 0 ? nil : confirmadas.suffix(Self.palavrasContexto).joined(separator: " ")
            let p = prompt(contexto: ctx)
            let (emb, mel) = try modelo.codificar(audio[ini..<fimAmostra])
            var d = try decodificarComReparo(p, emb, reparos: &reparos)
            d = try recomecoComTemperatura(d, prompt: p, irmao: prompt(contexto: ctx, limpo: true),
                                           emb: emb, mel: mel, recomecos: &recomecos)
            var locais = CrisperTempos.calcular(ids: d.ids, atencao: d.atencao, mel: mel, tok: tok)
            if let ext = try recuperarFimPrecoce(d, locais: locais, prompt: p, emb: emb, mel: mel, ultimo: ultimo) {
                d = ext
                fimRecuperado += 1
                locais = CrisperTempos.calcular(ids: d.ids, atencao: d.atencao, mel: mel, tok: tok)
            }
            if locais.isEmpty { continue }
            // descarta as últimas palavras só se a próxima janela as ouvir de novo
            var manter = locais.count
            if !ultimo {
                let legado = max(locais.count - Self.descartar, 0)
                if locais.contains(where: { $0.i != nil }) {
                    var primeiraSobreposta = locais.count
                    for (j, w) in locais.enumerated() where (w.i ?? -1) >= Self.passo { primeiraSobreposta = j; break }
                    manter = max(legado, primeiraSobreposta)
                } else { manter = legado }
            }
            let seguras = Array(locais.prefix(manter))
            confirmadas += seguras.map { $0.p }
            for w in seguras {
                guard let i = w.i, let f = w.f else { continue }
                globais.append(PalavraTempo(p: w.p, i: ((i + inicioSeg) * 1000).rounded() / 1000,
                                            f: ((f + inicioSeg) * 1000).rounded() / 1000))
            }
        }
        // nenhuma palavra começa antes do fim da anterior
        if globais.count > 1 {
            for j in 1..<globais.count {
                let fimAnt = globais[j - 1].f ?? 0
                if (globais[j].i ?? 0) < fimAnt {
                    globais[j].i = fimAnt
                    globais[j].f = max(fimAnt, globais[j].f ?? fimAnt)
                }
            }
        }
        progresso(1, "Pronto")
        return Resultado(texto: confirmadas.joined(separator: " "), palavras: globais,
                         segundosAudio: Double(audio.count) / taxa, reparos: reparos,
                         recomecos: recomecos, fimRecuperado: fimRecuperado)
    }

    // MARK: áudio de entrada

    /// Qualquer áudio ou vídeo -> 16 kHz mono em Float.
    static func lerAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let trilhas = try await asset.loadTracks(withMediaType: .audio)
        guard !trilhas.isEmpty else { throw ErroApp("Esse arquivo não tem áudio.") }
        let leitor = try AVAssetReader(asset: asset)
        let ajustes: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let saida = AVAssetReaderAudioMixOutput(audioTracks: trilhas, audioSettings: ajustes)
        leitor.add(saida)
        guard leitor.startReading() else { throw ErroApp("Não consegui ler o áudio: \(leitor.error?.localizedDescription ?? "")") }
        var amostras: [Float] = []
        while let buf = saida.copyNextSampleBuffer() {
            guard let bloco = CMSampleBufferGetDataBuffer(buf) else { continue }
            let n = CMBlockBufferGetDataLength(bloco) / 4 * 4
            if n < 4 { continue }
            var parte = [Float](repeating: 0, count: n / 4)
            parte.withUnsafeMutableBytes { p in
                _ = CMBlockBufferCopyDataBytes(bloco, atOffset: 0, dataLength: n, destination: p.baseAddress!)
            }
            amostras += parte
        }
        if leitor.status == .failed { throw ErroApp("Falha ao ler o áudio: \(leitor.error?.localizedDescription ?? "")") }
        return amostras
    }
}
