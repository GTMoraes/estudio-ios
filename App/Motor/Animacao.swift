import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// GIF e WebP animado a partir de um trecho do vídeo: os quadros saem da mesma composição do
/// conversor (giro, enquadramento, desfoque, velocidade), em SDR 8 bits, no fps escolhido.
enum Animacao {
    static func gerar(_ entrada: URL, info: InfoMidia, o: OpcoesConversao, pasta: URL, base: String,
                      cancel: Cancelamento, progresso: @escaping ConversorVideo.Progresso) async throws -> URL {
        let asset = AVURLAsset(url: entrada)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ErroApp("Esse arquivo não tem vídeo.")
        }
        let (tam, transf) = try await vtrack.load(.naturalSize, .preferredTransform)
        let duracaoTotal = try await asset.load(.duration)
        let faixa = ConversorVideo.intervalo(info, o)
        let (w, h) = PlanoConversao.dimensoesAnimado(info, o)
        let fps = Double(max(1, o.fpsAnimado))

        let veloz = PlanoConversao.mudaVelocidade(o)
        var fonte: AVAsset = asset
        var vUsar: AVAssetTrack = vtrack
        var duracaoInstr = duracaoTotal
        var duracaoSaida = faixa.duration
        if veloz {
            let (c, cv, _) = try await Velocidade.composicao(asset, faixa: faixa, velocidade: o.velocidade, comVideo: true)
            guard let cv else { throw ErroApp("Não consegui montar o vídeo com a nova velocidade.") }
            fonte = c; vUsar = cv
            duracaoInstr = c.duration
            duracaoSaida = c.duration
        }

        // SDR: o próprio iOS converte o HDR (GIF e WebP são 8 bits)
        let cor = ConversorVideo.coresDeSaida(info, hdr: false)
        let comp = try await ConversorVideo.composicao(fonte: fonte, trilha: vUsar, tam: tam, transf: transf,
                                                       duracao: duracaoInstr, o: o, w: w, h: h, fps: fps, cor: cor)
        let reader = try AVAssetReader(asset: fonte)
        if !veloz { reader.timeRange = faixa }
        let saida = AVAssetReaderVideoCompositionOutput(videoTracks: [vUsar],
                                                        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        saida.videoComposition = comp
        saida.alwaysCopiesSampleData = false
        guard reader.canAdd(saida) else { throw ErroApp("O iPhone não conseguiu ler esse vídeo.") }
        reader.add(saida)

        let gif = o.acao == .gif
        let destino = Nuvem.semColisao(pasta.appendingPathComponent("\(base).\(gif ? "gif" : "webp")"))
        let inicio = veloz ? CMTime.zero : faixa.start
        let total = max(0.1, CMTimeGetSeconds(duracaoSaida))
        let qualidade = Float(o.qualidadeAnimada)
        let repetir = o.repetirAnimado

        return try await Task.detached(priority: .userInitiated) {
            guard reader.startReading() else {
                throw ErroApp("Falha ao ler: \(reader.error?.localizedDescription ?? "desconhecida")")
            }
            defer { if reader.status == .reading { reader.cancelReading() } }
            var quadrosGif: [CGImage] = []
            var anim: OpaquePointer?
            if !gif {
                guard let a = cod_webpanim_abrir(Int32(w), Int32(h), qualidade, repetir ? 0 : 1) else {
                    throw ErroApp("Não consegui iniciar o WebP animado.")
                }
                anim = a
            }
            var falhouWebP = false
            defer { if let a = anim { var sobra: UnsafeMutablePointer<UInt8>?; var tam0 = 0; _ = cod_webpanim_fechar(a, 0, &sobra, &tam0); if let sobra { cod_webp_liberar(sobra) } } }
            var ultimo = -1.0
            var n = 0
            while let amostra = saida.copyNextSampleBuffer() {
                if cancel.cancelado { throw CancellationError() }
                guard let px = CMSampleBufferGetImageBuffer(amostra) else { continue }
                let t = max(0, CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(amostra), inicio)))
                CVPixelBufferLockBaseAddress(px, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
                guard let baseEnd = CVPixelBufferGetBaseAddress(px) else { continue }
                let passo = CVPixelBufferGetBytesPerRow(px)
                let pw = CVPixelBufferGetWidth(px), ph = CVPixelBufferGetHeight(px)
                if gif {
                    // cópia dos pixels (o buffer do leitor é reaproveitado)
                    let dados = Data(bytes: baseEnd, count: passo * ph)
                    guard let prov = CGDataProvider(data: dados as CFData),
                          let img = CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: passo,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                            provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                    else { continue }
                    quadrosGif.append(img)
                } else if let a = anim, pw == w, ph == h {
                    let r = cod_webpanim_quadro(a, baseEnd.assumingMemoryBound(to: UInt8.self), Int32(passo), Int32((t * 1000).rounded()))
                    if r != 0 { falhouWebP = true; break }
                }
                n += 1
                let p = min(1, t / total)
                if p - ultimo >= 0.01 { ultimo = p; progresso(p * 0.95) }
            }
            if reader.status == .failed {
                throw ErroApp("Falha ao ler o vídeo: \(reader.error?.localizedDescription ?? "desconhecida")")
            }
            if falhouWebP { throw ErroApp("Falha ao codificar o WebP animado.") }
            guard n > 0 else { throw ErroApp("Nenhum quadro no trecho escolhido.") }

            if gif {
                guard let dest = CGImageDestinationCreateWithURL(destino as CFURL, UTType.gif.identifier as CFString, quadrosGif.count, nil) else {
                    throw ErroApp("Não consegui criar o GIF.")
                }
                let atraso = 1.0 / fps
                CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: repetir ? 0 : 1]] as CFDictionary)
                let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: atraso,
                                                             kCGImagePropertyGIFUnclampedDelayTime: atraso]] as CFDictionary
                for (k, img) in quadrosGif.enumerated() {
                    if cancel.cancelado { throw CancellationError() }
                    CGImageDestinationAddImage(dest, img, props)
                    if k % 10 == 0 { progresso(0.95 + 0.04 * Double(k) / Double(quadrosGif.count)) }
                }
                guard CGImageDestinationFinalize(dest) else { throw ErroApp("Falha ao gravar o GIF.") }
            } else if let a = anim {
                anim = nil
                var p: UnsafeMutablePointer<UInt8>?
                var tamanho = 0
                let r = cod_webpanim_fechar(a, Int32((total * 1000).rounded()), &p, &tamanho)
                guard r == 0, let p else { throw ErroApp("Falha ao montar o WebP animado (\(r)).") }
                defer { cod_webp_liberar(p) }
                try Data(bytes: p, count: tamanho).write(to: destino, options: .atomic)
            }
            progresso(1)
            return destino
        }.value
    }
}
