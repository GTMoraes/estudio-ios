import Foundation
import AVFoundation
import WhisperKit

/// Transcrição no próprio iPhone (WhisperKit, Core ML no Neural Engine).
/// O modelo fica em Application Support/Modelos, dentro do app.
actor TranscritorLocal {
    static let shared = TranscritorLocal()

    struct Modelo: Identifiable, Hashable {
        let id: String          // variante no repositório argmaxinc/whisperkit-coreml
        let nome: String
        let tamanho: String
    }

    static let modelos: [Modelo] = [
        Modelo(id: "openai_whisper-large-v3-v20240930_turbo_632MB", nome: "Large v3 Turbo (recomendado)", tamanho: "≈ 630 MB"),
        Modelo(id: "openai_whisper-large-v3-v20240930_626MB", nome: "Large v3 Turbo (sem otimização de velocidade)", tamanho: "≈ 630 MB"),
        Modelo(id: "openai_whisper-small", nome: "Small (rápido, menos preciso)", tamanho: "≈ 480 MB"),
    ]
    static let modeloPadrao = modelos[0].id

    private var whisper: WhisperKit?
    private var carregado: String?

    static var pastaModelos: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Modelos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var v = url
        var r = URLResourceValues(); r.isExcludedFromBackup = true
        try? v.setResourceValues(r)
        return url
    }

    /// Pasta do modelo já baixado (procura a variante em qualquer subpasta).
    static func pastaDoModelo(_ id: String) -> URL? {
        guard let e = FileManager.default.enumerator(at: pastaModelos, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let u as URL in e where u.lastPathComponent == id {
            let ok = FileManager.default.fileExists(atPath: u.appendingPathComponent("AudioEncoder.mlmodelc").path)
                && FileManager.default.fileExists(atPath: u.appendingPathComponent("TextDecoder.mlmodelc").path)
            if ok { return u }
        }
        return nil
    }

    static func tamanhoEmDisco() -> Int64 {
        guard let e = FileManager.default.enumerator(at: pastaModelos, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func apagarModelos() {
        whisper = nil; carregado = nil
        try? FileManager.default.removeItem(at: Self.pastaModelos)
    }

    func baixar(_ id: String, progresso: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let p = Self.pastaDoModelo(id) { return p }
        return try await WhisperKit.download(variant: id, downloadBase: Self.pastaModelos,
                                             progressCallback: { p in progresso(p.fractionCompleted) })
    }

    /// Carregamento em andamento: um ator pode ser reentrado a cada `await`, e dois pedidos
    /// ao mesmo tempo baixavam o tokenizer juntos (um apagava o arquivo do outro).
    private var carregando: (id: String, tarefa: Task<WhisperKit, Error>)?

    private func preparar(_ id: String, avisar: @escaping @Sendable (String, Double?) -> Void) async throws -> WhisperKit {
        if let w = whisper, carregado == id { return w }
        if let c = carregando, c.id == id { return try await c.tarefa.value }
        let t = Task { try await self.carregar(id, avisar: avisar) }
        carregando = (id, t)
        defer { if carregando?.id == id { carregando = nil } }
        return try await t.value
    }

    private func carregar(_ id: String, avisar: @escaping @Sendable (String, Double?) -> Void) async throws -> WhisperKit {
        if let w = whisper, carregado == id { return w }
        whisper = nil
        avisar("Baixando o modelo (só na primeira vez)", 0)
        let pasta = try await baixar(id) { p in avisar("Baixando o modelo (só na primeira vez)", p) }
        // O iOS compila o modelo para o Neural Engine deste iPhone e guarda num cache; o cache
        // se perde quando o app é instalado/atualizado (muda a pasta do app) ou o iOS atualiza.
        let jaCompilado = Self.compilado(id)
        avisar(jaCompilado ? "Carregando o modelo no Neural Engine"
                           : "Compilando o modelo para o Neural Engine deste iPhone: leva 3 a 4 min e só acontece depois de instalar ou atualizar o app (ou o iOS)", nil)
        // downloadBase também vira a pasta do tokenizer (sem ele, vai para Documentos/huggingface)
        let cfg = WhisperKitConfig(model: id, downloadBase: Self.pastaModelos, modelFolder: pasta.path,
                                   verbose: false, logLevel: .error,
                                   prewarm: true, load: true, download: false)
        let w = try await WhisperKit(cfg)
        CacheCompilacao.marcar("whisper-" + id)
        whisper = w; carregado = id
        return w
    }

    /// Compilado para o Neural Engine desde a última instalação do app / atualização do iOS.
    static func compilado(_ id: String) -> Bool { CacheCompilacao.feito("whisper-" + id) }

    /// Ajustes › "Deixar o app pronto": baixa e compila agora, depois solta o modelo da memória
    /// (a compilação fica no cache do iOS; carregar de novo leva segundos).
    func prepararDeAntemao(_ id: String, avisar: @escaping @Sendable (String, Double?) -> Void) async throws {
        let jaCarregado = whisper != nil && carregado == id
        _ = try await preparar(id, avisar: avisar)
        if !jaCarregado { whisper = nil; carregado = nil }
    }

    /// Transcreve um arquivo de áudio ou vídeo. idioma: "pt" ou nil (detectar).
    func transcrever(_ arquivo: URL, modelo: String, idioma: String?,
                     avisar: @escaping @Sendable (String, Double?) -> Void) async throws -> [Segmento] {
        let w = try await preparar(modelo, avisar: avisar)
        avisar("Lendo o áudio", nil)
        let audio = try await AudioUtil.extrairAudio(arquivo)
        defer { if audio != arquivo { try? FileManager.default.removeItem(at: audio) } }

        let opcoes = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: idioma,
            temperature: 0,
            usePrefillPrompt: idioma != nil,
            detectLanguage: idioma == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        // o progresso do WhisperKit é um Progress; lido a cada meio segundo
        let acompanhar = Task {
            while !Task.isCancelled {
                avisar("Transcrevendo no iPhone", w.progress.fractionCompleted)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { acompanhar.cancel() }
        func converter(_ r: [TranscriptionResult]) -> [Segmento] {
            r.flatMap { $0.segments }.map { s in
                Segmento(inicio: Double(s.start), fim: Double(s.end),
                         texto: s.text.trimmingCharacters(in: .whitespacesAndNewlines),
                         palavras: (s.words ?? []).map {
                             Segmento.Palavra(inicio: Double($0.start), fim: Double($0.end), texto: $0.word)
                         })
            }
        }
        let resultados = try await w.transcribe(audioPath: audio.path, decodeOptions: opcoes)
        let duracao = await AudioUtil.duracao(arquivo)
        var segmentos = Self.arrumar(Self.semInvencoes(converter(resultados).sorted { $0.inicio < $1.inicio },
                                                       duracao: duracao, idioma: idioma))

        // O Whisper às vezes "pula" um pedaço: para no meio de uma frase e só volta vários segundos
        // depois. Onde ficou um buraco de fala sem texto, aquele pedaço do áudio é cortado para um
        // arquivo à parte e transcrito sozinho (sem os filtros que descartam trechos "duvidosos").
        if let d = duracao, d > 0 {
            for (a, b) in Self.buracos(segmentos, duracao: d).prefix(12) where Self.temSom(audio, de: a, ate: b) {
                acompanhar.cancel()
                avisar("Conferindo um trecho que ficou sem texto", nil)
                // pedaços de até 26 s (a janela do Whisper é de 30), cortados num ponto calmo
                let ini = max(0, a - 0.25), fim = min(d, b + 0.25)
                var t = ini
                while t < fim - 0.4 {
                    var e = min(fim, t + 26)
                    if e < fim { e = Self.pontoCalmo(audio, entre: t + 19, e: t + 26) ?? e }
                    defer { t = e }
                    guard let pedaco = Self.recortar(audio, de: t, ate: e) else { continue }
                    defer { try? FileManager.default.removeItem(at: pedaco) }
                    var op = opcoes
                    op.chunkingStrategy = ChunkingStrategy.none
                    op.noSpeechThreshold = nil
                    op.logProbThreshold = nil
                    op.compressionRatioThreshold = nil
                    var novos = (try? await w.transcribe(audioPath: pedaco.path, decodeOptions: op)).map(converter) ?? []
                    if novos.allSatisfy({ $0.texto.isEmpty }) {
                        // última tentativa: só o texto, sem pedir tempos (o editor reparte o tempo pelas palavras)
                        op.withoutTimestamps = true
                        op.wordTimestamps = false
                        novos = (try? await w.transcribe(audioPath: pedaco.path, decodeOptions: op)).map(converter) ?? []
                        novos = novos.map { s in var n = s; n.palavras = []; n.inicio = 0; n.fim = e - t; return n }
                    }
                    // do relógio do pedaço para o do arquivo, e só o que cai dentro do buraco
                    let deslocados = novos.filter { !$0.texto.isEmpty }.map { s -> Segmento in
                        var n = s
                        n.inicio = min(e, t + max(0, s.inicio)); n.fim = min(e, t + max(0, s.fim))
                        if n.fim <= n.inicio { n.inicio = t; n.fim = e }
                        n.palavras = s.palavras.map { Segmento.Palavra(inicio: t + $0.inicio, fim: min(e, t + $0.fim), texto: $0.texto) }
                            .filter { $0.inicio >= a - 0.15 && $0.inicio < b + 0.05 }
                        if !s.palavras.isEmpty && n.palavras.isEmpty { n.texto = "" }       // tudo fora do buraco
                        return n
                    }.filter { !$0.texto.isEmpty }
                    segmentos += Self.arrumar(Self.semInvencoes(deslocados, duracao: duracao, idioma: idioma))
                }
            }
            segmentos.sort { $0.inicio < $1.inicio }
        }
        return segmentos
    }

    /// Deixa cada trecho justo nas palavras dele: começo e fim pelos tempos das palavras, texto
    /// igual às palavras, e um trecho novo onde há 3 s ou mais entre uma palavra e a seguinte
    /// (é assim que um "pulo" do Whisper aparece: o trecho continua, mas as palavras somem).
    static func arrumar(_ segmentos: [Segmento]) -> [Segmento] {
        var saida: [Segmento] = []
        for s in segmentos {
            let ps = s.palavras.filter { !$0.texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !ps.isEmpty else { saida.append(s); continue }
            var grupo: [Segmento.Palavra] = []
            func fechar() {
                guard let p = grupo.first, let u = grupo.last else { return }
                saida.append(Segmento(inicio: p.inicio, fim: max(u.fim, p.inicio),
                                      texto: grupo.map(\.texto).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                                      palavras: grupo))
                grupo = []
            }
            for p in ps {
                if let u = grupo.last, p.inicio - u.fim >= 3 { fechar() }
                grupo.append(p)
            }
            fechar()
        }
        return saida
    }

    /// Corta um pedaço do áudio para um arquivo .wav temporário.
    static func recortar(_ audio: URL, de a: Double, ate b: Double) -> URL? {
        guard let arq = try? AVAudioFile(forReading: audio) else { return nil }
        let fmt = arq.processingFormat
        let ini = AVAudioFramePosition(max(0, a) * fmt.sampleRate)
        var falta = min(AVAudioFramePosition((b - a) * fmt.sampleRate), arq.length - ini)
        guard falta > 0 else { return nil }
        let destino = FileManager.default.temporaryDirectory.appendingPathComponent("trecho-" + UUID().uuidString + ".wav")
        guard let saida = try? AVAudioFile(forWriting: destino, settings: fmt.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate * 5)) else { return nil }
        arq.framePosition = ini
        while falta > 0 {
            let pedir = AVAudioFrameCount(min(AVAudioFramePosition(buf.frameCapacity), falta))
            guard (try? arq.read(into: buf, frameCount: pedir)) != nil, buf.frameLength > 0,
                  (try? saida.write(from: buf)) != nil else { break }
            falta -= AVAudioFramePosition(buf.frameLength)
        }
        return destino
    }

    /// O instante mais calmo entre dois tempos (para cortar entre palavras, não no meio de uma).
    static func pontoCalmo(_ audio: URL, entre a: Double, e b: Double) -> Double? {
        guard b > a, let arq = try? AVAudioFile(forReading: audio) else { return nil }
        let taxa = arq.processingFormat.sampleRate
        let ini = AVAudioFramePosition(max(0, a) * taxa)
        let total = min(AVAudioFramePosition((b - a) * taxa), arq.length - ini)
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: arq.processingFormat, frameCapacity: AVAudioFrameCount(total)) else { return nil }
        arq.framePosition = ini
        guard (try? arq.read(into: buf, frameCount: AVAudioFrameCount(total))) != nil, let canal = buf.floatChannelData?[0] else { return nil }
        let n = Int(buf.frameLength), janela = max(1, Int(taxa * 0.08))
        guard n > janela * 2 else { return nil }
        var menor = Double.infinity, onde = n / 2
        var k = 0
        while k + janela <= n {
            var soma = 0.0
            for i in k..<(k + janela) { let v = Double(canal[i]); soma += v * v }
            if soma < menor { menor = soma; onde = k + janela / 2 }
            k += janela / 2
        }
        return a + Double(onde) / taxa
    }

    /// Intervalos de 3 s ou mais sem nenhum texto (no começo, no meio e no fim).
    static func buracos(_ s: [Segmento], duracao: Double) -> [(Double, Double)] {
        var saida: [(Double, Double)] = []
        var cursor = 0.0
        for x in s {
            if x.inicio - cursor >= 3 { saida.append((cursor, x.inicio)) }
            cursor = max(cursor, x.fim)
        }
        if duracao - cursor >= 3 { saida.append((cursor, duracao)) }
        return saida
    }

    /// O trecho tem som de verdade (fala, música) ou é silêncio? Volume médio acima de −38 dB.
    /// Em silêncio não vale a pena transcrever de novo: é onde o Whisper inventa frases.
    static func temSom(_ audio: URL, de a: Double, ate b: Double) -> Bool {
        guard let arq = try? AVAudioFile(forReading: audio) else { return true }
        let taxa = arq.processingFormat.sampleRate
        let ini = AVAudioFramePosition(max(0, a) * taxa)
        let total = min(AVAudioFramePosition((b - a) * taxa), arq.length - ini)
        guard total > 0 else { return false }
        arq.framePosition = ini
        var soma = 0.0, n = 0.0
        var falta = total
        let pedaco = AVAudioFrameCount(taxa * 5)
        guard let buf = AVAudioPCMBuffer(pcmFormat: arq.processingFormat, frameCapacity: pedaco) else { return true }
        while falta > 0 {
            let pedir = AVAudioFrameCount(min(AVAudioFramePosition(pedaco), falta))
            guard (try? arq.read(into: buf, frameCount: pedir)) != nil, buf.frameLength > 0,
                  let canal = buf.floatChannelData?[0] else { break }
            for i in 0..<Int(buf.frameLength) { let v = Double(canal[i]); soma += v * v }
            n += Double(buf.frameLength)
            falta -= AVAudioFramePosition(buf.frameLength)
        }
        guard n > 0 else { return false }
        return (soma / n).squareRoot() > 0.0125
    }

    /// O Whisper trabalha em janelas de 30 s; a última é completada com silêncio, e no silêncio ele
    /// às vezes "ouve" uma frase de fim de vídeo que viu no treino ("Продолжение следует...",
    /// "Legendas pela comunidade…"), com tempo depois do fim do arquivo. Tira o que começa depois do
    /// fim e, quando o idioma é português, o que vem em outro alfabeto.
    static func semInvencoes(_ segmentos: [Segmento], duracao: Double?, idioma: String?) -> [Segmento] {
        func outroAlfabeto(_ t: String) -> Bool {
            t.unicodeScalars.contains { u in
                u.properties.isAlphabetic && !(u.value < 0x250 || (0x1E00...0x1EFF).contains(u.value))
            }
        }
        return segmentos.compactMap { s -> Segmento? in
            if let d = duracao, d > 0, s.inicio >= d - 0.05 { return nil }
            if idioma == "pt", outroAlfabeto(s.texto) { return nil }
            var n = s
            if let d = duracao, d > 0 {
                n.fim = min(n.fim, d)
                n.palavras = n.palavras.filter { $0.inicio < d }.map { p in
                    var q = p; q.fim = min(q.fim, d); return q
                }
            }
            return n
        }
    }
}

enum AudioUtil {
    /// Vídeo ou formato que o leitor de áudio não abre → extrai a trilha em .m4a.
    static func extrairAudio(_ arquivo: URL) async throws -> URL {
        if (try? AVAudioFile(forReading: arquivo)) != nil { return arquivo }
        let asset = AVURLAsset(url: arquivo)
        let trilhas = try await asset.loadTracks(withMediaType: .audio)
        guard !trilhas.isEmpty else {
            throw ErroApp("Esse arquivo não tem áudio.")
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ErroApp("Não consegui ler o áudio desse arquivo.")
        }
        let destino = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try await export.export(to: destino, as: .m4a)
        return destino
    }

    static func duracao(_ arquivo: URL) async -> Double? {
        let asset = AVURLAsset(url: arquivo)
        guard let d = try? await asset.load(.duration) else { return nil }
        let s = CMTimeGetSeconds(d)
        return s.isFinite ? s : nil
    }
}

struct ErroApp: LocalizedError {
    let mensagem: String
    init(_ m: String) { mensagem = m }
    var errorDescription: String? { mensagem }
}
