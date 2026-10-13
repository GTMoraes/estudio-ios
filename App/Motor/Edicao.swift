import Foundation
import AVFoundation
import CoreMedia
import UIKit

// MARK: - projeto

/// Um pedaço de um dos vídeos de origem, numa posição da linha do tempo.
struct TrechoEdicao: Codable, Identifiable, Equatable {
    var id = UUID()
    var fonte: Int                 // índice em `ProjetoEdicao.fontes`
    var inicio: Double             // segundos no arquivo de origem
    var fim: Double
    var velocidade: Double = 1     // 0,25 … 4 (o tom da voz é mantido)
    var volume: Double = 1         // 0 … 1
    /// Onde o trecho começa na linha do tempo (nil = logo depois do anterior: projetos da 0.19.0).
    var posicao: Double?
    /// Recorte de quando o trecho foi criado/dividido: as alças grudam aqui com o ímã ligado.
    var corteInicio: Double?
    var corteFim: Double?

    var duracaoOrigem: Double { max(0, fim - inicio) }
    var duracao: Double { duracaoOrigem / max(0.1, velocidade) }
    var naLinha: Double { posicao ?? 0 }
    var fimNaLinha: Double { naLinha + duracao }
}

/// A edição inteira: os vídeos usados e os trechos. Fica guardada no resultado para
/// "Editar de novo" (os vídeos vão para Originais/<id>).
struct ProjetoEdicao: Codable, Equatable {
    var fontes: [String]           // nomes dos arquivos (na pasta de trabalho / Originais)
    var trechos: [TrechoEdicao]

    /// Fim do último trecho (espaço vazio depois dele não conta).
    var duracao: Double { Self.posicionados(trechos).map { $0.fimNaLinha }.max() ?? 0 }

    /// Trechos com posição definida (os sem posição vão logo depois do anterior), na ordem da linha do tempo.
    static func posicionados(_ t: [TrechoEdicao]) -> [TrechoEdicao] {
        var fim = 0.0
        let comPos = t.map { x -> TrechoEdicao in
            var y = x
            if y.posicao == nil { y.posicao = fim }
            if y.corteInicio == nil { y.corteInicio = y.inicio }
            if y.corteFim == nil { y.corteFim = y.fim }
            fim = max(fim, y.fimNaLinha)
            return y
        }
        return comPos.sorted { $0.naLinha < $1.naLinha }
    }

    /// Há algum espaço vazio entre (ou antes dos) trechos?
    static func temEspacos(_ t: [TrechoEdicao]) -> Bool {
        var fim = 0.0
        for x in posicionados(t) {
            if x.naLinha - fim > 0.02 { return true }
            fim = max(fim, x.fimNaLinha)
        }
        return false
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

/// Monta os trechos numa composição única: uma trilha de vídeo e uma de áudio, cada trecho na sua
/// posição e com a sua velocidade; espaço vazio = tela preta e silêncio. O primeiro vídeo define o
/// formato (os outros entram inteiros, centrados, com barras pretas se a proporção for outra).
/// Volume: trecho mudo nem leva o som; volume parcial vai em `ganhos` (a gravação aplica nas
/// amostras) e em rampas do mixer (a prévia).
struct MontagemEdicao {
    let composicao: AVMutableComposition
    let video: AVMutableCompositionTrack?
    let audio: AVMutableCompositionTrack?
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVMutableAudioMix?
    let ganhos: [GanhoAudio]
    let duracao: Double
    let temEspacos: Bool

    /// Tamanho de exibição (já girado) de um vídeo.
    static func tamanhoExibicao(_ asset: AVAsset) async throws -> CGSize? {
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (tam, t) = try await v.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: tam).applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// `tela`: tamanho do resultado. `fpsGrade`: nil = prévia (1/fps); com valor = gravação
    /// (o tempo dos quadros vem da própria trilha, como na conversão; com espaços vazios, grade fixa).
    static func montar(fontes: [URL], trechos: [TrechoEdicao], tela: CGSize, fps: Double,
                       cor: [String: String]?, fpsGrade: Double? = nil) async throws -> MontagemEdicao {
        let lista = ProjetoEdicao.posicionados(trechos).filter { $0.duracaoOrigem > 0.01 }
        guard !lista.isEmpty else { throw ErroApp("A edição está vazia.") }
        let comp = AVMutableComposition()
        let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let ts: CMTimeScale = 600
        var fimV = CMTime.zero, fimA = CMTime.zero      // onde cada trilha termina agora
        var transformacoes: [(CMTime, CGAffineTransform)] = []
        var ganhos: [GanhoAudio] = []
        var temVideo = false, temAudio = false
        var assets: [Int: AVURLAsset] = [:]

        /// Completa a trilha com vazio até `t` (só se ela terminar antes).
        func completar(_ trilha: AVMutableCompositionTrack, _ fim: inout CMTime, ate t: CMTime) {
            if CMTimeCompare(t, fim) > 0 {
                trilha.insertEmptyTimeRange(CMTimeRange(start: fim, end: t))
                fim = t
            }
        }

        for t in lista {
            guard t.fonte >= 0 && t.fonte < fontes.count else { continue }
            let asset = assets[t.fonte] ?? AVURLAsset(url: fontes[t.fonte])
            assets[t.fonte] = asset
            let faixa = CMTimeRange(start: CMTime(seconds: t.inicio, preferredTimescale: ts),
                                    end: CMTime(seconds: t.fim, preferredTimescale: ts))
            guard CMTimeCompare(faixa.duration, .zero) > 0 else { continue }
            // a posição nunca volta para antes do que já foi montado
            var cursor = CMTime(seconds: t.naLinha, preferredTimescale: ts)
            let ocupado = CMTimeMaximum(fimV, fimA)
            if CMTimeCompare(cursor, ocupado) < 0 { cursor = ocupado }

            if let v = try await asset.loadTracks(withMediaType: .video).first, let cv {
                let existe = try await v.load(.timeRange)
                let r = CMTimeRangeGetIntersection(faixa, otherRange: existe)
                if CMTimeCompare(r.duration, .zero) > 0 {
                    let em = CMTimeAdd(cursor, CMTimeSubtract(r.start, faixa.start))
                    completar(cv, &fimV, ate: em)
                    try cv.insertTimeRange(r, of: v, at: em)
                    fimV = CMTimeAdd(em, r.duration)
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
            // mudo: o som do trecho nem entra (silêncio garantido)
            if t.volume > 0.001, let a = try await asset.loadTracks(withMediaType: .audio).first, let ca {
                let existe = try await a.load(.timeRange)
                let r = CMTimeRangeGetIntersection(faixa, otherRange: existe)
                if CMTimeCompare(r.duration, .zero) > 0 {
                    let em = CMTimeAdd(cursor, CMTimeSubtract(r.start, faixa.start))
                    completar(ca, &fimA, ate: em)
                    try ca.insertTimeRange(r, of: a, at: em)
                    fimA = CMTimeAdd(em, r.duration)
                    temAudio = true
                }
            }
            let v = max(0.1, t.velocidade)
            let novo = CMTimeMultiplyByFloat64(faixa.duration, multiplier: 1.0 / v)
            if abs(t.velocidade - 1) > 0.001 {
                comp.scaleTimeRange(CMTimeRange(start: cursor, duration: faixa.duration), toDuration: novo)
                // o fim de cada trilha dentro do trecho encolhe/estica junto
                func reescala(_ f: CMTime) -> CMTime {
                    guard CMTimeCompare(f, cursor) > 0 else { return f }
                    return CMTimeAdd(cursor, CMTimeMultiplyByFloat64(CMTimeSubtract(f, cursor), multiplier: 1.0 / v))
                }
                fimV = reescala(fimV); fimA = reescala(fimA)
            }
            if t.volume > 0.001 && t.volume < 0.999 {
                let ini = CMTimeGetSeconds(cursor)
                ganhos.append(GanhoAudio(inicio: ini, fim: ini + CMTimeGetSeconds(novo), ganho: Float(t.volume)))
            }
        }
        guard temVideo || temAudio else { throw ErroApp("Os trechos escolhidos estão vazios.") }
        if !temVideo, let cv { comp.removeTrack(cv) }
        if !temAudio, let ca { comp.removeTrack(ca) }
        let espacos = ProjetoEdicao.temEspacos(lista)

        var vc: AVMutableVideoComposition?
        if temVideo, let cv {
            let c = AVMutableVideoComposition()
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            instr.backgroundColor = UIColor.black.cgColor
            let camada = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
            for (t, tr) in transformacoes { camada.setTransform(tr, at: t) }
            instr.layerInstructions = [camada]
            c.instructions = [instr]
            c.renderSize = tela
            if let fpsGrade {
                if espacos {
                    // nos espaços a trilha não tem quadros: a grade fixa (2× o fps) desenha o preto
                    c.frameDuration = ConversorVideo.duracaoDoQuadro(fpsGrade)
                } else {
                    c.sourceTrackIDForFrameTiming = cv.trackID
                    c.frameDuration = ConversorVideo.duracaoDoQuadro(fpsGrade)
                }
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
        // prévia: volume parcial por rampas constantes (a gravação aplica `ganhos` direto nas amostras)
        var mix: AVMutableAudioMix?
        if temAudio, let ca, !ganhos.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: ca)
            for g in ganhos {
                p.setVolumeRamp(fromStartVolume: g.ganho, toEndVolume: g.ganho,
                                timeRange: CMTimeRange(start: CMTime(seconds: g.inicio, preferredTimescale: ts),
                                                       end: CMTime(seconds: g.fim, preferredTimescale: ts)))
                // depois do trecho o volume volta a 100% (o último valor do mixer continuaria valendo)
                if !ganhos.contains(where: { abs($0.inicio - g.fim) < 0.001 }) {
                    p.setVolume(1, at: CMTime(seconds: g.fim, preferredTimescale: ts))
                }
            }
            let m = AVMutableAudioMix()
            m.inputParameters = [p]
            mix = m
        }
        return MontagemEdicao(composicao: comp, video: temVideo ? cv : nil, audio: temAudio ? ca : nil,
                              videoComposition: vc, audioMix: mix, ganhos: ganhos,
                              duracao: CMTimeGetSeconds(comp.duration), temEspacos: espacos)
    }
}

/// Volume de um intervalo da edição (segundos no resultado).
struct GanhoAudio: Sendable {
    let inicio: Double
    let fim: Double
    let ganho: Float

    /// Multiplica as amostras PCM de 16 bits pelo volume de cada instante. Sem nada a mudar, devolve a mesma.
    static func aplicar(_ ganhos: [GanhoAudio], em sb: CMSampleBuffer) -> CMSampleBuffer {
        guard !ganhos.isEmpty,
              let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mBitsPerChannel == 16, asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              let bloco = CMSampleBufferGetDataBuffer(sb) else { return sb }
        let n = CMSampleBufferGetNumSamples(sb)
        let canais = max(1, Int(asbd.mChannelsPerFrame))
        let taxa = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        let t0 = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        guard n > 0, t0.isFinite else { return sb }
        let t1 = t0 + Double(n) / taxa
        let aqui = ganhos.filter { $0.fim > t0 && $0.inicio < t1 }
        guard !aqui.isEmpty else { return sb }
        let bytes = n * canais * 2
        guard CMBlockBufferGetDataLength(bloco) >= bytes else { return sb }
        var dados = [Int16](repeating: 0, count: n * canais)
        let r = dados.withUnsafeMutableBytes { p in
            CMBlockBufferCopyDataBytes(bloco, atOffset: 0, dataLength: bytes, destination: p.baseAddress!)
        }
        guard r == kCMBlockBufferNoErr else { return sb }
        for i in 0..<n {
            let t = t0 + Double(i) / taxa
            guard let g = aqui.first(where: { t >= $0.inicio && t < $0.fim }) else { continue }
            for c in 0..<canais {
                let k = i * canais + c
                dados[k] = Int16(clamping: Int((Float(dados[k]) * g.ganho).rounded()))
            }
        }
        var novoBloco: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &novoBloco) == kCMBlockBufferNoErr,
              let nb = novoBloco else { return sb }
        let rr = dados.withUnsafeBytes { p in
            CMBlockBufferReplaceDataBytes(with: p.baseAddress!, blockBuffer: nb, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard rr == kCMBlockBufferNoErr else { return sb }
        var novo: CMSampleBuffer?
        let st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nb, formatDescription: fd, sampleCount: n,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb), packetDescriptions: nil,
            sampleBufferOut: &novo)
        return st == noErr ? (novo ?? sb) : sb
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
                return [try await gravarAudio(fontes: fontes, trechos: trechos, pasta: pasta, base: base,
                                              cancel: cancel, progresso: progresso)]
            case .video:
                return [try await gravarVideo(fontes: fontes, trechos: trechos, o: o, pasta: pasta, base: base,
                                              cancel: cancel, progresso: progresso)]
            case .separados:
                var saida: [URL] = []
                let lista = ProjetoEdicao.posicionados(trechos)
                for (k, t0) in lista.enumerated() {
                    try Task.checkCancellation()
                    var t = t0
                    t.posicao = 0                      // cada arquivo começa no próprio trecho
                    let nome = base + "-" + String(format: "%02d", k + 1)
                    let n = Double(lista.count)
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
        guard let primeiro = ProjetoEdicao.posicionados(trechos).first else { throw ErroApp("A edição está vazia.") }
        var info = try await InfoMidia.ler(fontes[primeiro.fonte])
        guard info.temVideo else { throw ErroApp("O primeiro trecho não tem vídeo.") }
        info.duracao = ProjetoEdicao(fontes: [], trechos: trechos).duracao
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
        let primeiro = AVURLAsset(url: fontes[ProjetoEdicao.posicionados(trechos)[0].fonte])
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
            aOut.alwaysCopiesSampleData = false               // o volume entra nas amostras (ver `ganhos`)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000, AVEncoderBitRateKey: oc.audioKbps * 1000])
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut), writer.canAdd(aIn) {
                reader.add(aOut); writer.add(aIn); pares.append((aOut, aIn))
            }
        }
        let ganhos = m.ganhos
        var ajustes: [Int: @Sendable (CMSampleBuffer) -> CMSampleBuffer] = [:]
        if !ganhos.isEmpty && pares.count > 1 { ajustes[1] = { GanhoAudio.aplicar(ganhos, em: $0) } }
        try await Bombeador.bombear(reader: reader, writer: writer, pares: pares, inicio: .zero, duracao: m.duracao,
                                    cancel: cancel, progresso: progresso, quadro: ConversorVideo.duracaoDoQuadro(p.fps),
                                    ajustes: ajustes)
        return destino
    }

    static func gravarAudio(fontes: [URL], trechos: [TrechoEdicao], pasta: URL, base: String,
                            cancel: Cancelamento, progresso: @escaping ConversorVideo.Progresso) async throws -> URL {
        let m = try await MontagemEdicao.montar(fontes: fontes, trechos: trechos, tela: CGSize(width: 16, height: 16),
                                                fps: 30, cor: nil)
        guard let ca = m.audio else { throw ErroApp("Esses trechos não têm áudio.") }
        let reader = try AVAssetReader(asset: m.composicao)
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000]
        let aOut = AVAssetReaderAudioMixOutput(audioTracks: [ca], audioSettings: pcm)
        aOut.audioTimePitchAlgorithm = .spectral
        aOut.alwaysCopiesSampleData = false
        guard reader.canAdd(aOut) else { throw ErroApp("Não consegui ler o áudio da edição.") }
        reader.add(aOut)
        let destino = Nuvem.semColisao(pasta.appendingPathComponent("\(base).m4a"))
        let writer = try AVAssetWriter(outputURL: destino, fileType: .m4a)
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48000, AVEncoderBitRateKey: 192_000])
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(aIn) else { throw ErroApp("Não consegui preparar o áudio.") }
        writer.add(aIn)
        let ganhos = m.ganhos
        var ajustes: [Int: @Sendable (CMSampleBuffer) -> CMSampleBuffer] = [:]
        if !ganhos.isEmpty { ajustes[0] = { GanhoAudio.aplicar(ganhos, em: $0) } }
        try await Bombeador.bombear(reader: reader, writer: writer, pares: [(aOut, aIn)], inicio: .zero, duracao: m.duracao,
                                    cancel: cancel, progresso: progresso, ajustes: ajustes)
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
