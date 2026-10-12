import Foundation
import AVFoundation
import CoreMedia
import UIKit

// MARK: - projeto

/// Um pedaço de um dos vídeos de origem, na ordem da linha do tempo.
struct TrechoEdicao: Codable, Identifiable, Equatable {
    var id = UUID()
    var fonte: Int                 // índice em `ProjetoEdicao.fontes`
    var inicio: Double             // segundos no arquivo de origem
    var fim: Double
    var velocidade: Double = 1     // 0,25 … 4 (o tom da voz é mantido)
    var volume: Double = 1         // 0 … 1

    var duracaoOrigem: Double { max(0, fim - inicio) }
    var duracao: Double { duracaoOrigem / max(0.1, velocidade) }
}

/// A edição inteira: os vídeos usados e os trechos, na ordem. Fica guardada no resultado para
/// "Editar de novo" (os vídeos vão para Originais/<id>).
struct ProjetoEdicao: Codable, Equatable {
    var fontes: [String]           // nomes dos arquivos (na pasta de trabalho / Originais)
    var trechos: [TrechoEdicao]

    var duracao: Double { trechos.reduce(0) { $0 + $1.duracao } }
    /// Início de cada trecho na linha do tempo.
    var inicios: [Double] {
        var t = 0.0
        return trechos.map { let i = t; t += $0.duracao; return i }
    }
}

enum ModoGravacaoEdicao: String, Codable, CaseIterable, Identifiable {
    case video, separados, audio, semRecodificar
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .video: return "Um vídeo"
        case .separados: return "Cada trecho"
        case .audio: return "Só o áudio"
        case .semRecodificar: return "Sem regravar"
        }
    }
}

// MARK: - montagem (a mesma para a prévia e para a gravação)

/// Monta os trechos numa composição única: uma trilha de vídeo e uma de áudio, cada trecho com a
/// sua velocidade; o primeiro vídeo define o formato (os outros entram inteiros, centrados, com
/// barras pretas se a proporção for outra); volume por trecho.
struct MontagemEdicao {
    let composicao: AVMutableComposition
    let video: AVMutableCompositionTrack?
    let audio: AVMutableCompositionTrack?
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVMutableAudioMix?
    let duracao: Double

    /// Tamanho de exibição (já girado) de um vídeo.
    static func tamanhoExibicao(_ asset: AVAsset) async throws -> CGSize? {
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (tam, t) = try await v.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: tam).applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// `tela`: tamanho do resultado. `fpsGrade`: nil = prévia (1/fps); com valor = gravação
    /// (o tempo dos quadros vem da própria trilha, como na conversão).
    static func montar(fontes: [URL], trechos: [TrechoEdicao], tela: CGSize, fps: Double,
                       cor: [String: String]?, fpsGrade: Double? = nil) async throws -> MontagemEdicao {
        guard !trechos.isEmpty else { throw ErroApp("A edição está vazia.") }
        let comp = AVMutableComposition()
        let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let ts: CMTimeScale = 600
        var cursor = CMTime.zero
        var transformacoes: [(CMTime, CGAffineTransform)] = []
        var volumes: [(CMTime, Float)] = []
        var temVideo = false, temAudio = false
        var assets: [Int: AVURLAsset] = [:]

        for t in trechos {
            guard t.fonte >= 0 && t.fonte < fontes.count else { continue }
            let asset = assets[t.fonte] ?? AVURLAsset(url: fontes[t.fonte])
            assets[t.fonte] = asset
            let faixa = CMTimeRange(start: CMTime(seconds: t.inicio, preferredTimescale: ts),
                                    end: CMTime(seconds: t.fim, preferredTimescale: ts))
            guard CMTimeCompare(faixa.duration, .zero) > 0 else { continue }
            if let v = try await asset.loadTracks(withMediaType: .video).first, let cv {
                let existe = try await v.load(.timeRange)
                let r = CMTimeRangeGetIntersection(faixa, otherRange: existe)
                if CMTimeCompare(r.duration, .zero) > 0 {
                    try cv.insertTimeRange(r, of: v, at: CMTimeAdd(cursor, CMTimeSubtract(r.start, faixa.start)))
                    temVideo = true
                    // gira, encaixa no formato do resultado e centraliza
                    let (tam, pt) = try await v.load(.naturalSize, .preferredTransform)
                    let ex = CGRect(origin: .zero, size: tam).applying(pt)
                    let W = max(abs(ex.width), 1), H = max(abs(ex.height), 1)
                    let base = pt.concatenating(CGAffineTransform(translationX: -ex.minX, y: -ex.minY))
                    let pos: CGAffineTransform
                    if abs(W / H - tela.width / tela.height) < 0.01 {
                        pos = CGAffineTransform(scaleX: tela.width / W, y: tela.height / H)
                    } else {
                        let s = min(tela.width / W, tela.height / H)
                        pos = CGAffineTransform(scaleX: s, y: s)
                            .concatenating(CGAffineTransform(translationX: (tela.width - W * s) / 2, y: (tela.height - H * s) / 2))
                    }
                    transformacoes.append((cursor, base.concatenating(pos)))
                }
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first, let ca {
                let existe = try await a.load(.timeRange)
                let r = CMTimeRangeGetIntersection(faixa, otherRange: existe)
                if CMTimeCompare(r.duration, .zero) > 0 {
                    try ca.insertTimeRange(r, of: a, at: CMTimeAdd(cursor, CMTimeSubtract(r.start, faixa.start)))
                    temAudio = true
                }
            }
            volumes.append((cursor, Float(min(1, max(0, t.volume)))))
            let novo = CMTimeMultiplyByFloat64(faixa.duration, multiplier: 1.0 / max(0.1, t.velocidade))
            if abs(t.velocidade - 1) > 0.001 {
                comp.scaleTimeRange(CMTimeRange(start: cursor, duration: faixa.duration), toDuration: novo)
            }
            cursor = CMTimeAdd(cursor, novo)
        }
        guard temVideo || temAudio else { throw ErroApp("Os trechos escolhidos estão vazios.") }
        if !temVideo, let cv { comp.removeTrack(cv) }
        if !temAudio, let ca { comp.removeTrack(ca) }

        var vc: AVMutableVideoComposition?
        if temVideo, let cv {
            let c = AVMutableVideoComposition()
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            let camada = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
            for (t, tr) in transformacoes { camada.setTransform(tr, at: t) }
            instr.layerInstructions = [camada]
            c.instructions = [instr]
            c.renderSize = tela
            if let fpsGrade {
                c.sourceTrackIDForFrameTiming = cv.trackID
                c.frameDuration = ConversorVideo.duracaoDoQuadro(fpsGrade)
            } else {
                c.frameDuration = ConversorVideo.duracaoDoQuadro(fps)
            }
            if let cor {
                c.colorPrimaries = cor[AVVideoColorPrimariesKey]
                c.colorTransferFunction = cor[AVVideoTransferFunctionKey]
                c.colorYCbCrMatrix = cor[AVVideoYCbCrMatrixKey]
            }
            vc = c
        }
        var mix: AVMutableAudioMix?
        if temAudio, let ca, volumes.contains(where: { $0.1 < 0.999 }) {
            let p = AVMutableAudioMixInputParameters(track: ca)
            for (t, v) in volumes { p.setVolume(v, at: t) }
            let m = AVMutableAudioMix()
            m.inputParameters = [p]
            mix = m
        }
        return MontagemEdicao(composicao: comp, video: temVideo ? cv : nil, audio: temAudio ? ca : nil,
                              videoComposition: vc, audioMix: mix, duracao: CMTimeGetSeconds(comp.duration))
    }
}

// MARK: - gravação

enum ConversorEdicao {
    /// Grava a edição em `pasta`. Devolve os arquivos gerados.
    static func gravar(fontes: [URL], projeto: ProjetoEdicao, opcoes o: OpcoesConversao, modo: ModoGravacaoEdicao,
                       pasta: URL, base: String, progresso: @escaping ConversorVideo.Progresso) async throws -> [URL] {
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let trechos = projeto.trechos.filter { $0.duracaoOrigem > 0.01 }
        guard !trechos.isEmpty else { throw ErroApp("A edição está vazia.") }
        let cancel = Cancelamento()
        return try await withTaskCancellationHandler {
            switch modo {
            case .semRecodificar:
                guard trechos.count == 1, let t = trechos.first else {
                    throw ErroApp("Sem regravar só vale para um trecho de um vídeo só.")
                }
                let info = try await InfoMidia.ler(fontes[t.fonte])
                var oc = o
                oc.acao = .semRecodificar; oc.inicio = t.inicio; oc.fim = t.fim
                return [try await ConversorVideo.cortarSemRecodificar(fontes[t.fonte], info: info, o: oc, pasta: pasta,
                                                                      base: base, progresso: progresso)]
            case .audio:
                return [try await gravarAudio(fontes: fontes, trechos: trechos, pasta: pasta, base: base, progresso: progresso)]
            case .video:
                return [try await gravarVideo(fontes: fontes, trechos: trechos, o: o, pasta: pasta, base: base,
                                              cancel: cancel, progresso: progresso)]
            case .separados:
                var saida: [URL] = []
                for (k, t) in trechos.enumerated() {
                    try Task.checkCancellation()
                    let nome = base + "-" + String(format: "%02d", k + 1)
                    let n = Double(trechos.count)
                    saida.append(try await gravarVideo(fontes: fontes, trechos: [t], o: o, pasta: pasta, base: nome,
                                                       cancel: cancel, progresso: { p in progresso((Double(k) + p) / n) }))
                }
                return saida
            }
        } onCancel: { cancel.cancelar() }
    }

    /// Formato, cor e fps do resultado: os do primeiro vídeo.
    static func plano(fontes: [URL], trechos: [TrechoEdicao], o: OpcoesConversao) async throws
        -> (info: InfoMidia, w: Int, h: Int, hdr: Bool, cor: [String: String], fps: Double) {
        guard let primeiro = trechos.first else { throw ErroApp("A edição está vazia.") }
        var info = try await InfoMidia.ler(fontes[primeiro.fonte])
        guard info.temVideo else { throw ErroApp("O primeiro trecho não tem vídeo.") }
        info.duracao = trechos.reduce(0) { $0 + $1.duracao }
        var oc = o
        oc.inicio = nil; oc.fim = nil; oc.velocidade = 1; oc.enquadramento = nil; oc.legenda = nil; oc.acao = .video
        let (w, h) = PlanoConversao.dimensoes(info, oc)
        let hdr = PlanoConversao.hdrSaida(info, oc)
        return (info, w, h, hdr, ConversorVideo.coresDeSaida(info, hdr: hdr), PlanoConversao.fpsSaida(info, oc))
    }

    static func gravarVideo(fontes: [URL], trechos: [TrechoEdicao], o: OpcoesConversao, pasta: URL, base: String,
                            cancel: Cancelamento, progresso: @escaping ConversorVideo.Progresso) async throws -> URL {
        var oc = o
        oc.inicio = nil; oc.fim = nil; oc.velocidade = 1; oc.enquadramento = nil; oc.legenda = nil; oc.acao = .video
        let p = try await plano(fontes: fontes, trechos: trechos, o: oc)
        let maisRapido = trechos.map { $0.velocidade }.max() ?? 1
        let fpsFonte = (p.info.fps > 1 ? p.info.fps : 30) * max(1, maisRapido)
        let m = try await MontagemEdicao.montar(fontes: fontes, trechos: trechos, tela: CGSize(width: p.w, height: p.h),
                                                fps: p.fps, cor: p.cor, fpsGrade: min(480, fpsFonte * 2))
        guard let cv = m.video, let vcomp = m.videoComposition else { throw ErroApp("A edição não tem vídeo.") }

        let reader = try AVAssetReader(asset: m.composicao)
        let formatoPixel = p.hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [cv],
                                                       videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: formatoPixel])
        vOut.videoComposition = vcomp
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw ErroApp("O iPhone não conseguiu ler a edição.") }
        reader.add(vOut)

        let destino = Nuvem.semColisao(pasta.appendingPathComponent("\(base).mp4"))
        let writer = try AVAssetWriter(outputURL: destino, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let primeiro = AVURLAsset(url: fontes[trechos[0].fonte])
        writer.metadata = await ConversorVideo.metadadosSaida(primeiro, o: oc)
        var ambiente: Data?
        if p.hdr, let v0 = try await primeiro.loadTracks(withMediaType: .video).first,
           let fd = try await v0.load(.formatDescriptions).first {
            ambiente = CMFormatDescriptionGetExtension(fd, extensionKey: ConversorVideo.chaveAmbiente as CFString) as? Data
        }
        let taxa = PlanoConversao.taxaPorQualidade(p.info, oc, oc.qualidade)
        let vIn = AVAssetWriterInput(mediaType: .video,
                                     outputSettings: try ConversorVideo.ajustesVideo(writer, o: oc, info: p.info, w: p.w, h: p.h,
                                                                                    fps: p.fps, taxa: taxa, hdr: p.hdr,
                                                                                    cor: p.cor, ambiente: ambiente))
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var pares: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(vOut as AVAssetReaderOutput, vIn)]
        if let ca = m.audio {
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000]
            let aOut = AVAssetReaderAudioMixOutput(audioTracks: [ca], audioSettings: pcm)
            aOut.audioTimePitchAlgorithm = .spectral          // velocidade sem mudar o tom
            if let mix = m.audioMix { aOut.audioMix = mix }
            aOut.alwaysCopiesSampleData = false
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000, AVEncoderBitRateKey: oc.audioKbps * 1000])
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut), writer.canAdd(aIn) {
                reader.add(aOut); writer.add(aIn); pares.append((aOut, aIn))
            }
        }
        try await Bombeador.bombear(reader: reader, writer: writer, pares: pares, inicio: .zero, duracao: m.duracao,
                                    cancel: cancel, progresso: progresso, quadro: ConversorVideo.duracaoDoQuadro(p.fps))
        return destino
    }

    static func gravarAudio(fontes: [URL], trechos: [TrechoEdicao], pasta: URL, base: String,
                            progresso: @escaping ConversorVideo.Progresso) async throws -> URL {
        let m = try await MontagemEdicao.montar(fontes: fontes, trechos: trechos, tela: CGSize(width: 16, height: 16),
                                                fps: 30, cor: nil)
        guard m.audio != nil else { throw ErroApp("Esses trechos não têm áudio.") }
        if let v = m.video { m.composicao.removeTrack(v) }
        guard let exp = AVAssetExportSession(asset: m.composicao, presetName: AVAssetExportPresetAppleM4A) else {
            throw ErroApp("Não consegui preparar o áudio.")
        }
        exp.audioMix = m.audioMix
        exp.audioTimePitchAlgorithm = .spectral
        let destino = Nuvem.semColisao(pasta.appendingPathComponent("\(base).m4a"))
        let acompanhar = Task {
            for await estado in exp.states(updateInterval: 0.5) {
                if case .exporting(let p) = estado { progresso(p.fractionCompleted) }
            }
        }
        defer { acompanhar.cancel() }
        try await exp.export(to: destino, as: .m4a)
        progresso(1)
        return destino
    }
}

// MARK: - miniaturas e onda do som (para a linha do tempo)

actor AmostrasEdicao {
    static let shared = AmostrasEdicao()
    private var geradores: [URL: AVAssetImageGenerator] = [:]
    private var imagens: [String: UIImage] = [:]
    private var ondas: [URL: [Float]] = [:]

    /// Quadro do vídeo no instante `t` (arredondado a 0,5 s, guardado em memória).
    func miniatura(_ url: URL, _ t: Double) async -> UIImage? {
        let tr = (t * 2).rounded() / 2
        let chave = url.path + "@" + String(tr)
        if let i = imagens[chave] { return i }
        let g: AVAssetImageGenerator
        if let x = geradores[url] { g = x } else {
            g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 160, height: 160)
            g.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            g.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            geradores[url] = g
        }
        guard let r = try? await g.image(at: CMTime(seconds: tr, preferredTimescale: 600)) else { return nil }
        let img = UIImage(cgImage: r.image)
        if imagens.count > 600 { imagens.removeAll() }
        imagens[chave] = img
        return img
    }

    /// Volume do áudio em 20 pontos por segundo (0…1), para desenhar a onda.
    func onda(_ url: URL) async -> [Float] {
        if let o = ondas[url] { return o }
        var pontos: [Float] = []
        let asset = AVURLAsset(url: url)
        if let trilha = try? await asset.loadTracks(withMediaType: .audio).first,
           let leitor = try? AVAssetReader(asset: asset) {
            let ajustes: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000,
                                          AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                                          AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                          AVLinearPCMIsBigEndianKey: false]
            let saida = AVAssetReaderTrackOutput(track: trilha, outputSettings: ajustes)
            leitor.add(saida)
            if leitor.startReading() {
                var soma: Float = 0
                var n = 0
                while let buf = saida.copyNextSampleBuffer() {
                    guard let bloco = CMSampleBufferGetDataBuffer(buf) else { continue }
                    let tam = CMBlockBufferGetDataLength(bloco) / 4 * 4
                    if tam < 4 { continue }
                    var parte = [Float](repeating: 0, count: tam / 4)
                    parte.withUnsafeMutableBytes { p in
                        _ = CMBlockBufferCopyDataBytes(bloco, atOffset: 0, dataLength: tam, destination: p.baseAddress!)
                    }
                    for v in parte {
                        soma += v * v; n += 1
                        if n == 400 { pontos.append(sqrt(soma / 400)); soma = 0; n = 0 }
                    }
                }
            }
        }
        let maximo = max(pontos.max() ?? 1, 0.0001)
        let norm = pontos.map { min(1, $0 / maximo) }
        ondas[url] = norm
        return norm
    }
}
