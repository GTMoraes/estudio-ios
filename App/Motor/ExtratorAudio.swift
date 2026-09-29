import Foundation
import AVFoundation

/// Extrai/converte o áudio: M4A (copia o AAC quando dá), WAV, MP3 (LAME) e OGG Vorbis.
enum ExtratorAudio {
    static func extrair(_ entrada: URL, info: InfoMidia, o: OpcoesConversao, pasta: URL, base: String,
                        cancel: Cancelamento, progresso: @escaping ConversorVideo.Progresso) async throws -> URL {
        let asset = AVURLAsset(url: entrada)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ErroApp("Esse arquivo não tem áudio.")
        }
        let faixa = ConversorVideo.intervalo(info, o)
        let canais = min(2, max(1, info.canais))
        let taxaOrig = info.taxaAudio > 0 ? info.taxaAudio : 48000

        // velocidade ≠ 1: lê de uma composição com o tempo escalado; o áudio passa pelo
        // algoritmo que muda o andamento sem mudar o tom (AVAudioTimePitchAlgorithm.spectral)
        let veloz = abs(o.velocidade - 1) > 0.001
        var fonte: AVAsset = asset
        var trilha: AVAssetTrack = track
        var faixaLeitura: CMTimeRange? = faixa
        var inicio = faixa.start
        if veloz {
            let (comp, _, ca) = try await Velocidade.composicao(asset, faixa: faixa, velocidade: o.velocidade, comVideo: false)
            guard let ca else { throw ErroApp("Esse arquivo não tem áudio.") }
            fonte = comp; trilha = ca; faixaLeitura = nil; inicio = .zero
        }
        let duracao = CMTimeGetSeconds(faixa.duration) / o.velocidade
        func saidaAudio(_ ajustes: [String: Any]?) -> AVAssetReaderOutput {
            if veloz {
                let m = AVAssetReaderAudioMixOutput(audioTracks: [trilha], audioSettings: ajustes)
                m.audioTimePitchAlgorithm = .spectral
                return m
            }
            return AVAssetReaderTrackOutput(track: trilha, outputSettings: ajustes)
        }
        func novoLeitor() throws -> AVAssetReader {
            let r = try AVAssetReader(asset: fonte)
            if let faixaLeitura { r.timeRange = faixaLeitura }
            return r
        }

        switch o.formatoAudio {
        case .m4a, .wav:
            let reader = try novoLeitor()
            let ext = o.formatoAudio == .m4a ? "m4a" : "wav"
            let destino = Nuvem.semColisao(pasta.appendingPathComponent("\(base).\(ext)"))
            let writer = try AVAssetWriter(outputURL: destino, fileType: o.formatoAudio == .m4a ? .m4a : .wav)
            let saida: AVAssetReaderOutput
            let entradaW: AVAssetWriterInput
            if o.formatoAudio == .m4a && o.copiarAudio && info.audioAAC && !veloz {
                let fd = try await track.load(.formatDescriptions).first
                saida = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                entradaW = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fd)
            } else if o.formatoAudio == .m4a {
                saida = saidaAudio(pcm(taxa: 48000, canais: canais, float: false))
                entradaW = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: canais,
                    AVSampleRateKey: 48000, AVEncoderBitRateKey: o.audioKbps * 1000])
            } else {
                let taxa = o.wavTaxa > 0 ? Double(o.wavTaxa) : taxaOrig
                saida = saidaAudio(pcm(taxa: taxa, canais: canais, float: false))
                entradaW = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm(taxa: taxa, canais: canais, float: false))
            }
            guard reader.canAdd(saida), writer.canAdd(entradaW) else { throw ErroApp("Formato de áudio não suportado.") }
            saida.alwaysCopiesSampleData = false
            reader.add(saida); writer.add(entradaW)
            try await Bombeador.bombear(reader: reader, writer: writer, pares: [(saida, entradaW)],
                                        inicio: inicio, duracao: duracao, cancel: cancel, progresso: progresso)
            return destino

        case .mp3, .ogg:
            let taxa = (taxaOrig == 44100 || taxaOrig == 48000) ? taxaOrig : 48000
            let ext = o.formatoAudio == .mp3 ? "mp3" : "ogg"
            let destino = Nuvem.semColisao(pasta.appendingPathComponent("\(base).\(ext)"))
            let reader = try novoLeitor()
            let saida = saidaAudio(pcm(taxa: taxa, canais: canais, float: true))
            saida.alwaysCopiesSampleData = false
            guard reader.canAdd(saida) else { throw ErroApp("Não consegui ler o áudio desse arquivo.") }
            reader.add(saida)
            guard reader.startReading() else {
                throw ErroApp("Falha ao ler: \(reader.error?.localizedDescription ?? "?")")
            }
            let inicioLeitura = inicio       // (var não pode entrar na tarefa separada)
            // a codificação é trabalho pesado de CPU: roda fora do ator principal
            try await Task.detached(priority: .userInitiated) {
                try ExtratorAudio.codificar(reader: reader, saida: saida, destino: destino, mp3: ext == "mp3",
                              taxa: Int(taxa), canais: canais, o: o, inicio: inicioLeitura, duracao: duracao,
                              cancel: cancel, progresso: progresso)
            }.value
            return destino
        }
    }

    static func pcm(taxa: Double, canais: Int, float: Bool) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: taxa, AVNumberOfChannelsKey: canais,
         AVLinearPCMBitDepthKey: float ? 32 : 16, AVLinearPCMIsFloatKey: float,
         AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
    }

    private static func codificar(reader: AVAssetReader, saida: AVAssetReaderOutput, destino: URL, mp3: Bool,
                                  taxa: Int, canais: Int, o: OpcoesConversao, inicio: CMTime, duracao: Double,
                                  cancel: Cancelamento, progresso: ConversorVideo.Progresso) throws {
        var mp3Cod: OpaquePointer?
        var oggCod: OpaquePointer?
        if mp3 {
            mp3Cod = cod_mp3_abrir(destino.path, Int32(taxa), Int32(canais), Int32(o.mp3Kbps))
        } else {
            oggCod = cod_ogg_abrir(destino.path, Int32(taxa), Int32(canais), Float(o.oggQualidade))
        }
        guard mp3Cod != nil || oggCod != nil else {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: destino)
            throw ErroApp("Não consegui iniciar o codificador \(mp3 ? "MP3" : "OGG").")
        }

        var falha: String?
        var buffer = [Float]()
        var ultimo = -1.0
        while falha == nil {
            if cancel.cancelado { falha = "cancelado"; break }
            guard let amostra = saida.copyNextSampleBuffer() else { break }
            guard let bloco = CMSampleBufferGetDataBuffer(amostra) else { continue }
            let bytes = CMBlockBufferGetDataLength(bloco)
            let n = bytes / MemoryLayout<Float>.size
            if n == 0 { continue }
            if buffer.count < n { buffer = [Float](repeating: 0, count: n) }
            let st = buffer.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(bloco, atOffset: 0, dataLength: n * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            if st != kCMBlockBufferNoErr { falha = "falha ao ler o áudio"; break }
            let quadros = Int32(n / canais)
            let r: Int32 = buffer.withUnsafeBufferPointer { p in
                mp3 ? cod_mp3_escrever(mp3Cod, p.baseAddress, quadros) : cod_ogg_escrever(oggCod, p.baseAddress, quadros)
            }
            if r != 0 { falha = "o codificador falhou (\(r))"; break }
            let t = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(amostra), inicio))
            if t.isFinite, duracao > 0 {
                let p = min(1, max(0, t / duracao))
                if p - ultimo >= 0.005 { ultimo = p; progresso(p) }
            }
        }
        let fechou = mp3 ? cod_mp3_fechar(mp3Cod) : cod_ogg_fechar(oggCod)
        if reader.status == .failed { falha = falha ?? "falha ao ler: \(reader.error?.localizedDescription ?? "?")" }
        reader.cancelReading()
        if let falha {
            try? FileManager.default.removeItem(at: destino)
            if falha == "cancelado" { throw CancellationError() }
            throw ErroApp("A conversão falhou: \(falha).")
        }
        if fechou != 0 { throw ErroApp("Não consegui gravar o arquivo (\(fechou)).") }
        progresso(1)
    }
}
