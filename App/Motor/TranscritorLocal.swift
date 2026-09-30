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
        let resultados = try await w.transcribe(audioPath: audio.path, decodeOptions: opcoes)
        return resultados.flatMap { $0.segments }.map { s in
            Segmento(inicio: Double(s.start), fim: Double(s.end),
                     texto: s.text.trimmingCharacters(in: .whitespacesAndNewlines),
                     palavras: (s.words ?? []).map {
                         Segmento.Palavra(inicio: Double($0.start), fim: Double($0.end), texto: $0.word)
                     })
        }.sorted { $0.inicio < $1.inicio }
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
