import Foundation
import AVFoundation
import CoreML

/// Transcrição "verbatim" (tudo o que foi dito, com [UH], gaguejos e repetições) do CrisperWhisper,
/// seguindo o caminho longo do pacote oficial (`continuation_transcribe_with_word_timestamps`):
/// janelas de 30 s a cada 26 s, as últimas 12 palavras confirmadas como contexto da próxima janela,
/// descarte das palavras finais que a janela seguinte vai ouvir de novo, reparo de laços de repetição.
/// Ainda não portados (raramente entram em ação): o recomeço com temperatura para trechos que saem
/// vazios e a recuperação de fim de texto prematuro.
final class CrisperTranscritor: @unchecked Sendable {
    struct Resultado {
        var texto: String
        var palavras: [PalavraTempo]
        var segundosAudio: Double
        var reparos: Int
    }

    static let janela = 30.0, passo = 26.0
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

    /// Prompt do modo verbatim, com ou sem contexto (igual ao `PromptBuilder` oficial).
    func prompt(contexto: String?) -> [Int] {
        var texto = (1...5).map { "[verbatim_\($0)]" }.joined()
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
    private func decodificarComReparo(_ prompt: [Int], _ emb: MLMultiArray, reparos: inout Int) throws -> ([Int], [[Float]]) {
        var (gerados, atencao) = try modelo.decodificar(prompt: prompt, encoder: emb, maxNovos: Self.maxNovos, eot: tok.eot)
        for _ in 1...3 {
            guard let laco = Self.acharLaco(gerados) else { break }
            let inicio = laco.0, g = laco.1
            reparos += 1
            let corte = inicio + g.count
            let mantidos = Array(gerados.prefix(corte))
            let attMantida = Array(atencao.prefix(corte))
            let resta = Self.maxNovos - mantidos.count
            if resta <= 0 { gerados = mantidos; atencao = attMantida; break }
            let (cauda, attCauda) = try modelo.decodificar(prompt: prompt + mantidos, encoder: emb, maxNovos: resta,
                                                           banirNoPrimeiro: [g[0]], eot: tok.eot)
            gerados = mantidos + cauda
            atencao = attMantida + attCauda
        }
        return (gerados, atencao)
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
        var reparos = 0
        for (k, ini) in inicios.enumerated() {
            try Task.checkCancellation()
            let ultimo = k == inicios.count - 1
            let fimAmostra = min(ini + tamJanela, audio.count)
            let inicioSeg = Double(k) * Self.passo
            progresso(Double(k) / Double(inicios.count), "Trecho \(k + 1) de \(inicios.count)")
            let ctx = k == 0 ? nil : confirmadas.suffix(Self.palavrasContexto).joined(separator: " ")
            let p = prompt(contexto: ctx)
            let (emb, mel) = try modelo.codificar(audio[ini..<fimAmostra])
            let (ids, att) = try decodificarComReparo(p, emb, reparos: &reparos)
            let locais = CrisperTempos.calcular(ids: ids, atencao: att, mel: mel, tok: tok)
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
                         segundosAudio: Double(audio.count) / taxa, reparos: reparos)
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
