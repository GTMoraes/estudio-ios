import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Converte, no próprio iPhone, um vídeo que o iPhone não abre (VP9, VP8, MKV, WebM…):
/// o FFmpeg embutido decodifica e o codificador de hardware grava em HEVC ou H.264 (.mp4).
enum ConversorCompat {
    enum Codec: String { case hevc, h264 }

    private final class Sinal: @unchecked Sendable { var cancelado = false }

    static func converter(_ origem: URL, para destino: URL, codec: Codec,
                          progresso: @escaping @Sendable (Double) -> Void) async throws {
        let sinal = Sinal()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try executar(origem, destino, codec, sinal, progresso)
                        c.resume()
                    } catch {
                        try? FileManager.default.removeItem(at: destino)
                        c.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            sinal.cancelado = true
        }
    }

    private static func executar(_ origem: URL, _ destino: URL, _ codec: Codec, _ sinal: Sinal,
                                 _ progresso: @escaping @Sendable (Double) -> Void) throws {
        var info = EstudioInfo()
        var motivo = [CChar](repeating: 0, count: 256)
        guard let leitor = estudio_abrir(origem.path, &info, &motivo, 256) else {
            throw ErroApp("Não consegui ler o vídeo: " + String(cString: motivo))
        }
        defer { estudio_fechar(leitor) }
        guard info.temVideo == 1 else { throw ErroApp("O arquivo não tem vídeo.") }

        let dez = info.dezBits == 1 && codec == .hevc          // H.264 do iPhone é só 8 bits
        let largura = Int(info.largura), altura = Int(info.altura)
        let fps = info.fps > 1 ? min(info.fps, 120) : 30
        // taxa folgada para a regravação não aparecer: o dobro da original, com um piso pelo tamanho da imagem
        let pixels = Double(largura * altura)
        let piso = pixels * fps * (codec == .hevc ? 0.07 : 0.11)
        let alvo = Double(info.taxaVideo) * (codec == .hevc ? 2.0 : 2.6)
        let taxa = Int(min(80_000_000, max(piso, alvo)))

        try? FileManager.default.removeItem(at: destino)
        let escritor = try AVAssetWriter(outputURL: destino, fileType: .mp4)
        escritor.shouldOptimizeForNetworkUse = true

        var comp: [String: Any] = [
            AVVideoAverageBitRateKey: taxa,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if codec == .h264 {
            comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else {
            comp[AVVideoProfileLevelKey] = (dez ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
        }
        let cor = cores(info, altura: altura)
        let ajustesVideo: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: largura,
            AVVideoHeightKey: altura,
            AVVideoCompressionPropertiesKey: comp,
            AVVideoColorPropertiesKey: cor,
        ]
        let entradaV = AVAssetWriterInput(mediaType: .video, outputSettings: ajustesVideo)
        entradaV.expectsMediaDataInRealTime = false
        if info.rotacao != 0 { entradaV.transform = CGAffineTransform(rotationAngle: CGFloat(info.rotacao) * .pi / 180) }
        let formato: OSType = dez ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let atributos: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: formato,
            kCVPixelBufferWidthKey as String: largura,
            kCVPixelBufferHeightKey as String: altura,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let adaptador = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: entradaV, sourcePixelBufferAttributes: atributos)
        guard escritor.canAdd(entradaV) else { throw ErroApp("O iPhone não aceitou gravar este vídeo em \(codec == .hevc ? "HEVC" : "H.264").") }
        escritor.add(entradaV)

        var entradaA: AVAssetWriterInput?
        var formatoA: AVAudioFormat?
        if info.temAudio == 1, info.taxaAudio > 0,
           let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(info.taxaAudio),
                                 channels: AVAudioChannelCount(info.canais), interleaved: true) {
            let ajustesAudio: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: min(48_000, Int(info.taxaAudio)),
                AVNumberOfChannelsKey: Int(info.canais),
                AVEncoderBitRateKey: info.canais >= 2 ? 192_000 : 96_000,
            ]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: ajustesAudio, sourceFormatHint: f.formatDescription)
            a.expectsMediaDataInRealTime = false
            if escritor.canAdd(a) { escritor.add(a); entradaA = a; formatoA = f }
        }

        guard escritor.startWriting() else { throw falha(escritor) }
        escritor.startSession(atSourceTime: .zero)

        var filaV: [(CVPixelBuffer, CMTime)] = []
        var filaA: [CMSampleBuffer] = []
        let limiteV = max(4, Int(150_000_000 / (pixels * (dez ? 3 : 1.5))))
        let limiteA = 400
        var quadro = EstudioQuadro()
        var acabou = false
        var ultimoV = CMTime.invalid
        var ultimoAviso = -1.0

        while true {
            if sinal.cancelado { escritor.cancelWriting(); throw CancellationError() }
            if escritor.status == .failed { throw falha(escritor) }
            // entrega o que os codificadores aceitarem agora
            while let p = filaV.first, entradaV.isReadyForMoreMediaData {
                guard adaptador.append(p.0, withPresentationTime: p.1) else { throw falha(escritor) }
                filaV.removeFirst()
            }
            if let a = entradaA {
                while let s = filaA.first, a.isReadyForMoreMediaData {
                    guard a.append(s) else { throw falha(escritor) }
                    filaA.removeFirst()
                }
            }
            if acabou {
                if filaV.isEmpty && filaA.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.004); continue
            }
            // filas cheias: espera. Exceção: uma fila cheia e a outra vazia quer dizer que o gravador
            // está esperando a outra trilha, então é preciso ler mais para ela chegar.
            let vCheia = filaV.count >= limiteV, aCheia = filaA.count >= limiteA
            let esperaAudio = vCheia && entradaA != nil && filaA.isEmpty && filaV.count < limiteV * 3
            let esperaVideo = aCheia && filaV.isEmpty && filaA.count < limiteA * 10
            if (vCheia && !esperaAudio) || (aCheia && !esperaVideo) {
                Thread.sleep(forTimeInterval: 0.004); continue
            }

            if estudio_proximo(leitor, &quadro) <= 0 {
                acabou = true
                continue
            }
            if quadro.tipo == 1 {
                let t = CMTime(seconds: max(0, quadro.tempo), preferredTimescale: 90_000)
                if ultimoV.isValid, t <= ultimoV { continue }            // tempo repetido ou voltando: descarta
                guard let pb = novoQuadro(adaptador, atributos) else { throw ErroApp("Faltou memória para converter o vídeo.") }
                CVPixelBufferLockBaseAddress(pb, [])
                let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self)
                let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self)
                let r = estudio_copiar_video(leitor, y, Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)),
                                             c, Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1)), dez ? 1 : 0)
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard r == 0 else { throw ErroApp("Não consegui converter um quadro do vídeo.") }
                for (chave, valor) in cor {
                    let k: CFString = chave == AVVideoColorPrimariesKey ? kCVImageBufferColorPrimariesKey
                                    : chave == AVVideoTransferFunctionKey ? kCVImageBufferTransferFunctionKey
                                    : kCVImageBufferYCbCrMatrixKey
                    CVBufferSetAttachment(pb, k, valor as CFString, .shouldPropagate)
                }
                filaV.append((pb, t)); ultimoV = t
                if info.duracao > 0 {
                    let p = min(1, quadro.tempo / info.duracao)
                    if p - ultimoAviso >= 0.005 { ultimoAviso = p; progresso(p) }
                }
            } else if quadro.tipo == 2, let f = formatoA, entradaA != nil, quadro.amostras > 0 {
                guard let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(quadro.amostras)),
                      let dados = buf.floatChannelData?[0] else { continue }
                let n = estudio_copiar_audio(leitor, dados, quadro.amostras)
                guard n > 0 else { continue }
                buf.frameLength = AVAudioFrameCount(n)
                let escala = CMTimeScale(info.taxaAudio)
                let t = CMTime(value: CMTimeValue((max(0, quadro.tempo) * Double(info.taxaAudio)).rounded()), timescale: escala)
                if let s = amostra(buf, em: t, escala: escala) { filaA.append(s) }
            }
        }

        entradaV.markAsFinished()
        entradaA?.markAsFinished()
        let fim = DispatchSemaphore(value: 0)
        escritor.finishWriting { fim.signal() }
        fim.wait()
        guard escritor.status == .completed else { throw falha(escritor) }
        progresso(1)
    }

    private static func novoQuadro(_ a: AVAssetWriterInputPixelBufferAdaptor, _ atributos: [String: Any]) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let reserva = a.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, reserva, &pb) == kCVReturnSuccess { return pb }
        guard let largura = atributos[kCVPixelBufferWidthKey as String] as? Int,
              let altura = atributos[kCVPixelBufferHeightKey as String] as? Int,
              let formato = atributos[kCVPixelBufferPixelFormatTypeKey as String] as? OSType else { return nil }
        CVPixelBufferCreate(nil, largura, altura, formato, atributos as CFDictionary, &pb)
        return pb
    }

    private static func amostra(_ buf: AVAudioPCMBuffer, em t: CMTime, escala: CMTimeScale) -> CMSampleBuffer? {
        var s: CMSampleBuffer?
        var tempo = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: escala), presentationTimeStamp: t, decodeTimeStamp: .invalid)
        let r = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                     makeDataReadyCallback: nil, refcon: nil,
                                     formatDescription: buf.format.formatDescription,
                                     sampleCount: CMItemCount(buf.frameLength),
                                     sampleTimingEntryCount: 1, sampleTimingArray: &tempo,
                                     sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &s)
        guard r == noErr, let s else { return nil }
        let r2 = CMSampleBufferSetDataBufferFromAudioBufferList(s, blockBufferAllocator: kCFAllocatorDefault,
                                                                blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                flags: 0, bufferList: buf.audioBufferList)
        return r2 == noErr ? s : nil
    }

    /// As marcas de cor da fonte (códigos H.273) nas do AVFoundation; sem marca, BT.709 (ou 601 em vídeo pequeno).
    private static func cores(_ i: EstudioInfo, altura: Int) -> [String: String] {
        let primarias: String
        switch i.primarias {
        case 9: primarias = AVVideoColorPrimaries_ITU_R_2020
        case 6, 7: primarias = AVVideoColorPrimaries_SMPTE_C
        case 12: primarias = AVVideoColorPrimaries_P3_D65
        default: primarias = AVVideoColorPrimaries_ITU_R_709_2
        }
        let transferencia: String
        switch i.transferencia {
        case 16: transferencia = AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case 18: transferencia = AVVideoTransferFunction_ITU_R_2100_HLG
        default: transferencia = AVVideoTransferFunction_ITU_R_709_2
        }
        let matriz: String
        switch i.matriz {
        case 9, 10: matriz = AVVideoYCbCrMatrix_ITU_R_2020
        case 5, 6: matriz = AVVideoYCbCrMatrix_ITU_R_601_4
        case 2: matriz = altura < 720 ? AVVideoYCbCrMatrix_ITU_R_601_4 : AVVideoYCbCrMatrix_ITU_R_709_2
        default: matriz = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        return [AVVideoColorPrimariesKey: primarias, AVVideoTransferFunctionKey: transferencia, AVVideoYCbCrMatrixKey: matriz]
    }

    private static func falha(_ e: AVAssetWriter) -> Error {
        let d = e.error?.localizedDescription ?? "erro desconhecido"
        return ErroApp("A gravação falhou (\(d)). Se o Estúdio saiu da tela durante a conversão, deixe-o aberto e tente de novo.")
    }
}
