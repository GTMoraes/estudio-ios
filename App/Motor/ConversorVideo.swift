import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO

// MARK: - o que o arquivo tem

struct InfoMidia: Equatable {
    var duracao: Double = 0
    var temVideo = false
    var largura = 0               // já na orientação de exibição
    var altura = 0
    var fps: Double = 0           // taxa real: a de pico quando o vídeo tem fps variável
    var fpsMedio: Double = 0      // média (quadros ÷ duração); menor que `fps` quando é variável
    var fpsVariavel: Bool { fpsMedio > 1 && fps - fpsMedio > 1 }
    var hdr: Transferencia = .sdr
    var dolbyVision = false
    var codecVideo = ""
    var temAudio = false
    var audioAAC = false
    var canais = 2
    var taxaAudio: Double = 48000
    var tamanhoBytes: Int64 = 0

    enum Transferencia: String { case sdr = "SDR", hlg = "HDR (HLG)", pq = "HDR (PQ)" }

    var resumo: String {
        var p: [String] = []
        if temVideo {
            p.append("\(largura)×\(altura)")
            if fps > 0 { p.append(String(format: "%.0f fps", fps) + (fpsVariavel ? " (variável)" : "")) }
            p.append(codecVideo)
            p.append(dolbyVision ? "Dolby Vision" : hdr.rawValue)
        } else if temAudio {
            p.append("só áudio")
        }
        if let d = formatarDuracao(duracao) { p.append(d) }
        if tamanhoBytes > 0 { p.append(ByteCountFormatter.string(fromByteCount: tamanhoBytes, countStyle: .file)) }
        return p.joined(separator: " · ")
    }

    /// Vídeo de celular/gravação de tela costuma ter fps variável: o "nominal" é só a média
    /// (ex.: gravado a 30, média 20 porque caiu no escuro). Converter pela média jogaria quadros fora;
    /// vale a taxa de pico (o menor intervalo entre quadros), arredondada para uma taxa conhecida.
    static func fpsReal(medio: Double, menorQuadro: CMTime) -> Double {
        let s = CMTimeGetSeconds(menorQuadro)
        guard medio > 1, s.isFinite, s > 0 else { return medio }
        var pico = 1 / s
        // intervalo quebrado entre dois quadros daria um pico absurdo: ignora
        guard pico > medio * 1.05, pico <= medio * 3.2, pico <= 245 else { return medio }
        for padrao in [24.0, 25, 30, 48, 50, 60, 90, 100, 120, 240] where abs(pico - padrao) / padrao < 0.04 {
            pico = padrao
        }
        return pico
    }

    static func ler(_ url: URL) async throws -> InfoMidia {
        let asset = AVURLAsset(url: url)
        var i = InfoMidia()
        i.duracao = CMTimeGetSeconds(try await asset.load(.duration))
        i.tamanhoBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let videos = try await asset.loadTracks(withMediaType: .video)
        if let v = videos.first {
            let (tam, t, fps, fds) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let menorQuadro = (try? await v.load(.minFrameDuration)) ?? .invalid
            let r = CGRect(origin: .zero, size: tam).applying(t)
            i.temVideo = true
            i.largura = Int(abs(r.width).rounded()); i.altura = Int(abs(r.height).rounded())
            i.fpsMedio = Double(fps)
            i.fps = Self.fpsReal(medio: Double(fps), menorQuadro: menorQuadro)
            if let fd = fds.first {
                let sub = CMFormatDescriptionGetMediaSubType(fd)
                i.codecVideo = Self.nomeCodec(sub)
                if let tf = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                    if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { i.hdr = .hlg }
                    else if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { i.hdr = .pq }
                }
                let atomos = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
                let dv = atomos.map { $0.keys.contains("dvcC") || $0.keys.contains("dvvC") || $0.keys.contains("dvwC") } ?? false
                i.dolbyVision = dv || sub == 0x64766831 /* dvh1 */ || sub == 0x64766865 /* dvhe */
            }
            // reserva: alguns arquivos não trazem a curva na descrição do formato
            if i.hdr == .sdr {
                let caract = (try? await v.load(.mediaCharacteristics)) ?? []
                if caract.contains(.containsHDRVideo) || i.dolbyVision { i.hdr = .hlg }
            }
        }
        let audios = try await asset.loadTracks(withMediaType: .audio)
        if let a = audios.first {
            i.temAudio = true
            let fds = try await a.load(.formatDescriptions)
            if let fd = fds.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                i.audioAAC = asbd.mFormatID == kAudioFormatMPEG4AAC
                i.canais = Int(asbd.mChannelsPerFrame)
                i.taxaAudio = asbd.mSampleRate
            }
        }
        return i
    }

    static func nomeCodec(_ c: FourCharCode) -> String {
        switch c {
        case kCMVideoCodecType_HEVC, 0x64766831, 0x64766865: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes4444: return "ProRes"
        case 0x61763031: return "AV1"
        default:
            let b = [UInt8((c >> 24) & 255), UInt8((c >> 16) & 255), UInt8((c >> 8) & 255), UInt8(c & 255)]
            return String(bytes: b, encoding: .ascii) ?? "?"
        }
    }
}

// MARK: - opções

struct OpcoesConversao: Codable, Equatable {
    enum Acao: String, Codable, CaseIterable { case video, semRecodificar, audio, gif, webpAnimado }
    enum Codec: String, Codable, CaseIterable { case hevc, h264 }
    enum Saida: String, Codable { case manterHDR, sdr }
    enum FormatoAudio: String, Codable, CaseIterable, Identifiable {
        case m4a, mp3, ogg, wav
        var id: String { rawValue }
        var nome: String { rawValue.uppercased() }
    }

    var acao: Acao = .video
    var codec: Codec = .hevc
    enum ModoTaxa: String, Codable, CaseIterable { case qualidade, mbps, alvo }

    /// "1080" = 1080p: 1080 no LADO MENOR (1920×1080 deitado, 1080×1920 em pé), como no ConversorMidia.
    /// 0 = original; -1 = caixa personalizada (cabe em caixaLargura × caixaAltura).
    var ladoMenor = 1080
    var caixaLargura = 1920
    var caixaAltura = 1080
    var fps = 0                      // 0 = original (vira taxa constante)
    var saida: Saida = .manterHDR
    var manterDolbyVision = true
    var modoTaxa: ModoTaxa = .qualidade
    var qualidade = 0.55             // 0...1 → bits por pixel (mesma qualidade em qualquer resolução)
    var mbps = 8.0                   // modo .mbps
    var alvoMB = 50.0                // modo .alvo
    var velocidade = 1.0             // 0,5× … 4×; o áudio mantém o tom
    var copiarAudio = true           // AAC da origem entra sem recodificar
    var audioKbps = 192              // AAC quando precisa recodificar (vídeo e M4A)
    var formatoAudio: FormatoAudio = .m4a
    var mp3Kbps = 192
    var oggQualidade = 6.0           // 0...10
    var wavTaxa = 0                  // 0 = original
    var inicio: Double?
    var fim: Double?
    /// opcionais para os presets já gravados continuarem abrindo
    var dataAgora: Bool?             // true = data da conversão; nil/false = data do vídeo original
    var manterLocal: Bool?           // true = copia a localização (GPS) do original
    var usarDataAtual: Bool { get { dataAgora ?? false } set { dataAgora = newValue } }
    var manterLocalizacao: Bool { get { manterLocal ?? false } set { manterLocal = newValue } }

    /// Recorte / encaixe do quadro (nil = como o original). Vale para vídeo, GIF e WebP animado.
    var enquadramento: Enquadramento?
    /// Legenda gravada na imagem (vem do editor de legendas). Tempos no relógio do vídeo original.
    var legenda: ProjetoLegenda?
    // GIF e WebP animado (opcionais pelo mesmo motivo)
    var animLargura: Int?            // largura do resultado em px (nunca aumenta)
    var animFps: Int?
    var animRepetir: Bool?
    var animQualidade: Double?       // WebP: 0…100
    var larguraAnimada: Int { get { animLargura ?? 480 } set { animLargura = newValue } }
    var fpsAnimado: Int { get { animFps ?? 15 } set { animFps = newValue } }
    var repetirAnimado: Bool { get { animRepetir ?? true } set { animRepetir = newValue } }
    var qualidadeAnimada: Double { get { animQualidade ?? 75 } set { animQualidade = newValue } }

    var animado: Bool { acao == .gif || acao == .webpAnimado }
    /// Recodifica os quadros (onde o enquadramento se aplica)
    var refazQuadros: Bool { acao == .video || animado }

    var extensaoVideo: String { acao == .semRecodificar ? "" : "mp4" }
}

/// Como o quadro do vídeo vai para o resultado.
struct Enquadramento: Codable, Equatable {
    enum Modo: String, Codable, CaseIterable, Identifiable {
        case preencher, caber, desfocar, livre
        var id: String { rawValue }
        var nome: String {
            switch self {
            case .preencher: return "Preencher"
            case .caber: return "Caber"
            case .desfocar: return "Desfocado"
            case .livre: return "Livre"
            }
        }
        var dica: String {
            switch self {
            case .preencher: return "O vídeo cobre o formato inteiro; arraste e amplie para escolher o que fica."
            case .caber: return "O vídeo inteiro dentro do formato, com barras pretas onde sobrar."
            case .desfocar: return "O vídeo inteiro dentro do formato; o espaço que sobra é o próprio vídeo ampliado e desfocado."
            case .livre: return "Um retângulo qualquer do vídeo; o resultado sai no tamanho dele."
            }
        }
    }
    var modo: Modo = .preencher
    var proporcao: Double = 0.8          // largura/altura do resultado (preencher, caber, desfocar)
    var recorte = Recorte()              // região do vídeo, 0…1, já girado (preencher e livre)

    /// O mesmo enquadramento num vídeo de outro formato (lote): "preencher" mantém a proporção
    /// do resultado, o centro e o tamanho relativo (nada fica esticado); livre/caber/desfocado não mudam.
    func adaptado(de origem: (w: Double, h: Double), para destino: (w: Double, h: Double)) -> Enquadramento {
        guard modo == .preencher, proporcao > 0,
              abs(origem.w / origem.h - destino.w / destino.h) > 0.001 else { return self }
        func maior(_ w: Double, _ h: Double) -> (Double, Double) {     // maior recorte relativo na proporção
            var lpx = w, apx = w / proporcao
            if apx > h { apx = h; lpx = h * proporcao }
            return (lpx / w, apx / h)
        }
        let (l0, _) = maior(origem.w, origem.h)
        let fracao = min(1, max(0.05, recorte.largura / max(l0, 0.0001)))
        let (l1, a1) = maior(destino.w, destino.h)
        let nl = l1 * fracao, na = a1 * fracao
        let cx = recorte.x + recorte.largura / 2, cy = recorte.y + recorte.altura / 2
        var e = self
        e.recorte = Recorte(x: min(max(0, cx - nl / 2), 1 - nl), y: min(max(0, cy - na / 2), 1 - na), largura: nl, altura: na)
        return e
    }

    static let proporcoes: [(nome: String, valor: Double)] = [
        ("9:16", 9.0 / 16), ("4:5", 0.8), ("1:1", 1), ("4:3", 4.0 / 3), ("16:9", 16.0 / 9),
    ]
}

enum PresetConversao: String, CaseIterable, Identifiable {
    case instagramHDR, instagramCopia, instagramSDR, qualidade, menor, davinci, alvo, cortar, audio, gif, webpAnimado, personalizado
    var id: String { rawValue }

    var nome: String {
        switch self {
        case .instagramHDR: return "Instagram HDR (HEVC 10 bits)"
        case .instagramCopia: return "Instagram HDR – sem recodificar"
        case .instagramSDR: return "Instagram SDR (H.264)"
        case .qualidade: return "Qualidade / arquivo"
        case .menor: return "Menor arquivo"
        case .davinci: return "Preparar para o DaVinci"
        case .alvo: return "Alvo de tamanho"
        case .cortar: return "Cortar sem recodificar"
        case .audio: return "Extrair áudio"
        case .gif: return "GIF"
        case .webpAnimado: return "WebP animado"
        case .personalizado: return "Personalizado"
        }
    }

    var dica: String {
        switch self {
        case .instagramHDR: return "Mantém o HDR (HLG/BT.2020, 10 bits); 1080p (1920×1080 deitado, 1080×1920 em pé). Sai com Dolby Vision 8.4 (o iPhone gera de novo)."
        case .instagramCopia: return "Copia o vídeo sem recodificar: perda zero, mantém até o Dolby Vision. Mesmo tamanho do original."
        case .instagramSDR: return "H.264 1080p; vídeo HDR é convertido para SDR pelo próprio iOS."
        case .qualidade: return "Mantém resolução e fps, HEVC com taxa alta; áudio copiado quando dá."
        case .menor: return "HEVC com taxa baixa e no máximo 30 fps."
        case .davinci: return "H.264 SDR 8 bits com taxa de quadros constante (resolve o fps variável do iPhone); taxa alta."
        case .alvo: return "Você diz quantos MB; a taxa é calculada para caber (uma passagem, fica perto do alvo)."
        case .cortar: return "Corta o trecho escolhido sem recodificar (perda zero; o corte cai no keyframe)."
        case .audio: return "M4A (copia o AAC quando dá), MP3, OGG ou WAV."
        case .gif: return "Animação que abre em qualquer lugar. Limitado a 256 cores por quadro (degradês e pele ficam com faixas) e arquivo grande; HDR vira SDR. Sem som."
        case .webpAnimado: return "Animação com cores completas e arquivo 3 a 5× menor que o GIF. Abre em navegadores, WhatsApp e Telegram; alguns lugares só aceitam GIF. Sem som."
        case .personalizado: return "Os ajustes abaixo mandam."
        }
    }

    func aplicar(_ o: inout OpcoesConversao) {
        let trecho = (o.inicio, o.fim)
        let velocidade = o.velocidade          // trecho e velocidade são do arquivo, não do preset
        var n = OpcoesConversao()
        switch self {
        case .instagramHDR: n.codec = .hevc; n.ladoMenor = 1080; n.saida = .manterHDR; n.qualidade = 0.55
        case .instagramCopia: n.acao = .semRecodificar
        case .instagramSDR: n.codec = .h264; n.ladoMenor = 1080; n.saida = .sdr; n.qualidade = 0.55
        case .qualidade: n.codec = .hevc; n.ladoMenor = 0; n.qualidade = 0.75
        case .menor: n.codec = .hevc; n.ladoMenor = 0; n.fps = 30; n.qualidade = 0.25
        case .davinci: n.codec = .h264; n.ladoMenor = 0; n.saida = .sdr; n.qualidade = 1.0; n.copiarAudio = false; n.audioKbps = 320
        case .alvo: n.codec = .hevc; n.ladoMenor = 1080; n.modoTaxa = .alvo; n.alvoMB = 50; n.copiarAudio = false; n.audioKbps = 128
        case .cortar: n.acao = .semRecodificar
        case .audio: n.acao = .audio
        case .gif: n.acao = .gif; n.larguraAnimada = 480; n.fpsAnimado = 15
        case .webpAnimado: n.acao = .webpAnimado; n.larguraAnimada = 480; n.fpsAnimado = 15; n.qualidadeAnimada = 75
        case .personalizado: n = o
        }
        (n.inicio, n.fim) = trecho
        // escolhas do arquivo, não do preset
        n.enquadramento = o.enquadramento
        n.legenda = o.legenda
        n.dataAgora = o.dataAgora
        n.manterLocal = o.manterLocal
        if n.acao != .semRecodificar { n.velocidade = velocidade }
        o = n
    }
}

// MARK: - cálculo de tamanho e taxa

enum PlanoConversao {
    /// Dimensões de saída: nunca aumenta, mantém proporção, números pares.
    /// Tamanho "cheio" do resultado antes da escolha de resolução: o do vídeo, ou o do
    /// enquadramento (a região recortada, ou o formato que contém o vídeo inteiro).
    static func base(_ info: InfoMidia, _ o: OpcoesConversao) -> (Double, Double) {
        let W = Double(max(info.largura, 2)), H = Double(max(info.altura, 2))
        guard o.refazQuadros, let e = o.enquadramento else { return (W, H) }
        switch e.modo {
        case .preencher, .livre:
            return (max(2, e.recorte.largura * W), max(2, e.recorte.altura * H))
        case .caber, .desfocar:
            let p = e.proporcao > 0 ? e.proporcao : W / H
            return W / H > p ? (W, W / p) : (H * p, H)
        }
    }

    /// Dimensões do resultado para qualquer ação.
    static func dimensoesSaida(_ info: InfoMidia, _ o: OpcoesConversao) -> (Int, Int) {
        switch o.acao {
        case .semRecodificar, .audio: return (info.largura, info.altura)
        case .gif, .webpAnimado: return dimensoesAnimado(info, o)
        case .video: return dimensoes(info, o)
        }
    }

    /// GIF / WebP animado: largura escolhida (nunca aumenta), altura pela proporção, números pares.
    static func dimensoesAnimado(_ info: InfoMidia, _ o: OpcoesConversao) -> (Int, Int) {
        let (w, h) = base(info, o)
        let escala = min(1, Double(o.larguraAnimada) / w)
        func par(_ x: Double) -> Int { max(2, Int((x * escala / 2).rounded()) * 2) }
        return (par(w), par(h))
    }

    static func dimensoes(_ info: InfoMidia, _ o: OpcoesConversao) -> (Int, Int) {
        let (w, h) = base(info, o)
        var escala = 1.0
        if o.ladoMenor > 0 {
            escala = min(1, Double(o.ladoMenor) / min(w, h))
        } else if o.ladoMenor < 0, o.caixaLargura > 0, o.caixaAltura > 0 {
            escala = min(1, Double(o.caixaLargura) / w, Double(o.caixaAltura) / h)
        }
        func par(_ x: Double) -> Int { max(2, Int((x * escala / 2).rounded()) * 2) }
        return (par(w), par(h))
    }

    static func fpsSaida(_ info: InfoMidia, _ o: OpcoesConversao) -> Double {
        let orig = info.fps > 1 ? info.fps : 30
        return o.fps > 0 ? min(Double(o.fps), orig) : orig
    }

    static func hdrSaida(_ info: InfoMidia, _ o: OpcoesConversao) -> Bool {
        !o.animado && info.hdr != .sdr && o.codec == .hevc && o.saida == .manterHDR
    }

    /// Duração do resultado (trecho ÷ velocidade; sem recodificar a velocidade não se aplica).
    static func duracao(_ info: InfoMidia, _ o: OpcoesConversao) -> Double {
        let ini = max(0, o.inicio ?? 0), fim = min(info.duracao, o.fim ?? info.duracao)
        let v = o.acao == .semRecodificar ? 1 : max(0.1, o.velocidade)
        return max(0.1, (fim - ini) / v)
    }

    static func mudaVelocidade(_ o: OpcoesConversao) -> Bool {
        o.acao != .semRecodificar && abs(o.velocidade - 1) > 0.001
    }

    static func audioBps(_ info: InfoMidia, _ o: OpcoesConversao) -> Double {
        guard info.temAudio else { return 0 }
        return (o.copiarAudio && info.audioAAC && !mudaVelocidade(o)) ? 256_000 : Double(o.audioKbps) * 1000
    }

    /// Taxa por qualidade: bits por pixel × pixels × fps (a posição do controle vale
    /// a mesma qualidade de imagem em qualquer resolução).
    static func taxaPorQualidade(_ info: InfoMidia, _ o: OpcoesConversao, _ q: Double) -> Double {
        let (w, h) = dimensoes(info, o)
        var bpp = 0.03 + q * 0.12                   // HEVC
        if o.codec == .h264 { bpp *= 1.5 }
        if hdrSaida(info, o) { bpp *= 1.25 }
        return min(150_000_000, max(300_000, bpp * Double(w * h) * fpsSaida(info, o)))
    }

    /// Taxa de bits do vídeo (bps).
    static func taxaVideo(_ info: InfoMidia, _ o: OpcoesConversao) -> Double {
        switch o.modoTaxa {
        case .alvo:
            let total = max(0.5, o.alvoMB) * 8_000_000 / duracao(info, o)
            return max(300_000, (total - audioBps(info, o)) * 0.96)
        case .mbps:
            return min(150_000_000, max(300_000, o.mbps * 1_000_000))
        case .qualidade:
            return taxaPorQualidade(info, o, o.qualidade)
        }
    }

    static func tamanhoEstimado(_ info: InfoMidia, _ o: OpcoesConversao) -> Int64 {
        let dur = duracao(info, o)
        switch o.acao {
        case .semRecodificar:
            return Int64(Double(info.tamanhoBytes) * dur / max(info.duracao, 0.1))
        case .audio:
            let bps: Double
            switch o.formatoAudio {
            case .m4a: bps = info.audioAAC && o.copiarAudio ? 256_000 : Double(o.audioKbps) * 1000
            case .mp3: bps = Double(o.mp3Kbps) * 1000
            case .ogg: bps = 64_000 + o.oggQualidade * 22_000
            case .wav: bps = (o.wavTaxa > 0 ? Double(o.wavTaxa) : info.taxaAudio) * Double(min(info.canais, 2)) * 16
            }
            return Int64(bps * dur / 8)
        case .video:
            return Int64((taxaVideo(info, o) + audioBps(info, o)) * dur / 8)
        case .gif, .webpAnimado:
            // estimativa grosseira: bytes por pixel por quadro medidos em vídeos de celular
            let (w, h) = dimensoesAnimado(info, o)
            let quadros = dur * Double(o.fpsAnimado)
            let bpp = o.acao == .gif ? 0.26 : 0.02 + 0.0006 * o.qualidadeAnimada
            return Int64(Double(w * h) * quadros * bpp)
        }
    }
}

// MARK: - execução

/// Sinal de cancelamento visível dentro das filas de GCD.
final class Cancelamento: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelado = false
    var cancelado: Bool { lock.lock(); defer { lock.unlock() }; return _cancelado }
    func cancelar() { lock.lock(); _cancelado = true; lock.unlock() }
}

enum ConversorVideo {
    typealias Progresso = @Sendable (Double) -> Void

    /// Converte e devolve o arquivo gerado dentro de `pasta`.
    static func converter(_ entrada: URL, info: InfoMidia, opcoes o: OpcoesConversao, pasta: URL,
                          base: String, progresso: @escaping Progresso) async throws -> URL {
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let cancel = Cancelamento()
        return try await withTaskCancellationHandler {
            switch o.acao {
            case .semRecodificar:
                return try await cortarSemRecodificar(entrada, info: info, o: o, pasta: pasta, base: base, progresso: progresso)
            case .audio:
                return try await ExtratorAudio.extrair(entrada, info: info, o: o, pasta: pasta, base: base,
                                                       cancel: cancel, progresso: progresso)
            case .video:
                return try await recodificar(entrada, info: info, o: o, pasta: pasta, base: base,
                                             cancel: cancel, progresso: progresso)
            case .gif, .webpAnimado:
                return try await Animacao.gerar(entrada, info: info, o: o, pasta: pasta, base: base,
                                                cancel: cancel, progresso: progresso)
            }
        } onCancel: { cancel.cancelar() }
    }

    static func intervalo(_ info: InfoMidia, _ o: OpcoesConversao) -> CMTimeRange {
        let ini = max(0, o.inicio ?? 0)
        let fim = min(info.duracao, o.fim ?? info.duracao)
        let ts: CMTimeScale = 600
        return CMTimeRange(start: CMTime(seconds: ini, preferredTimescale: ts),
                           end: CMTime(seconds: max(fim, ini + 0.1), preferredTimescale: ts))
    }

    // --- corte sem recodificar

    static func cortarSemRecodificar(_ entrada: URL, info: InfoMidia, o: OpcoesConversao, pasta: URL,
                                     base: String, progresso: @escaping Progresso) async throws -> URL {
        let asset = AVURLAsset(url: entrada)
        guard let exp = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ErroApp("Não consegui preparar a cópia sem recodificar.")
        }
        let ext = entrada.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"
        let destino = Nuvem.semColisao(pasta.appendingPathComponent("\(base).\(ext)"))
        exp.timeRange = intervalo(info, o)
        exp.shouldOptimizeForNetworkUse = true
        exp.metadata = await Self.metadadosSaida(asset, o: o)
        let acompanhar = Task {
            for await estado in exp.states(updateInterval: 0.5) {
                if case .exporting(let p) = estado { progresso(p.fractionCompleted) }
            }
        }
        defer { acompanhar.cancel() }
        try await exp.export(to: destino, as: ext == "mp4" ? .mp4 : .mov)
        return destino
    }

    // --- recodificar

    static func recodificar(_ entrada: URL, info: InfoMidia, o: OpcoesConversao, pasta: URL, base: String,
                            cancel: Cancelamento, progresso: @escaping Progresso) async throws -> URL {
        let asset = AVURLAsset(url: entrada)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ErroApp("Esse arquivo não tem vídeo. Use \"Extrair áudio\".")
        }
        let atrack = try await asset.loadTracks(withMediaType: .audio).first
        let (tam, transf) = try await vtrack.load(.naturalSize, .preferredTransform)
        let duracaoTotal = try await asset.load(.duration)

        let hdr = PlanoConversao.hdrSaida(info, o)
        let (w, h) = PlanoConversao.dimensoes(info, o)
        let fps = PlanoConversao.fpsSaida(info, o)
        let taxa = PlanoConversao.taxaVideo(info, o)
        let faixa = intervalo(info, o)

        // velocidade ≠ 1: lê de uma composição com o tempo escalado (o trecho já vai nela)
        let veloz = PlanoConversao.mudaVelocidade(o)
        var fonte: AVAsset = asset
        var vUsar: AVAssetTrack = vtrack
        var aUsar: AVAssetTrack? = atrack
        var inicioSessao = faixa.start
        var duracaoInstr = duracaoTotal
        var duracaoSaida = faixa.duration
        if veloz {
            let (c, cv, ca) = try await Velocidade.composicao(asset, faixa: faixa, velocidade: o.velocidade, comVideo: true)
            guard let cv else { throw ErroApp("Não consegui montar o vídeo com a nova velocidade.") }
            fonte = c; vUsar = cv; aUsar = ca
            inicioSessao = .zero
            duracaoInstr = c.duration
            duracaoSaida = c.duration
        }

        // composição: orientação, enquadramento, escala, fps constante e espaço de cor de saída
        let cor = coresDeSaida(info, hdr: hdr)
        // A composição entrega TODOS os quadros da fonte (no tempo deles); quem põe na grade de saída
        // (fps constante, descarta o que sobra, repete o que falta) é o Bombeador. Uma grade fixa na
        // composição perdia 1 quadro a cada 3 em vídeo com tempo em microssegundos (CapCut/ffmpeg:
        // o quadro em 0,066667 s fica depois do instante 2/30 e nunca era mostrado → 20 fps).
        let fpsFonte = (info.fps > 1 ? info.fps : 30) * (veloz ? max(1, o.velocidade) : 1)
        let comp = try await composicao(fonte: fonte, trilha: vUsar, tam: tam, transf: transf, duracao: duracaoInstr,
                                        o: o, w: w, h: h, fps: fps, cor: cor, fpsGrade: min(480, fpsFonte * 2),
                                        tempoOriginal: Self.relogio(inicio: CMTimeGetSeconds(faixa.start),
                                                                    velocidade: veloz ? o.velocidade : nil))

        let reader = try AVAssetReader(asset: fonte)
        if !veloz { reader.timeRange = faixa }
        let formatoPixel = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vUsar],
                                                       videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: formatoPixel])
        vOut.videoComposition = comp
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw ErroApp("O iPhone não conseguiu ler esse vídeo.") }
        reader.add(vOut)

        let destino = Nuvem.semColisao(pasta.appendingPathComponent("\(base).mp4"))
        let writer = try AVAssetWriter(outputURL: destino, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = await Self.metadadosSaida(asset, o: o)

        // "ambiente de visualização" do HDR do iPhone (caixa amve): diz ao player em que luz
        // o vídeo foi gravado. Sem ele o iOS mostra o HLG com outro brilho. Copiado do original.
        var ambiente: Data?
        if hdr, let fd = try await vtrack.load(.formatDescriptions).first {
            ambiente = CMFormatDescriptionGetExtension(fd, extensionKey: Self.chaveAmbiente as CFString) as? Data
        }

        let vIn = AVAssetWriterInput(mediaType: .video,
                                     outputSettings: try ajustesVideo(writer, o: o, info: info, w: w, h: h, fps: fps, taxa: taxa,
                                                                      hdr: hdr, cor: cor, ambiente: ambiente))
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        // áudio: copia o AAC ou recodifica para AAC estéreo
        var aOut: AVAssetReaderOutput?
        var aIn: AVAssetWriterInput?
        if let atrack, let aUsar {
            if o.copiarAudio && info.audioAAC && !veloz {
                let fd = try await atrack.load(.formatDescriptions).first
                aOut = AVAssetReaderTrackOutput(track: atrack, outputSettings: nil)
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fd)
            } else {
                let canais = min(2, max(1, info.canais))
                let kbps = canais == 1 ? min(o.audioKbps, 192) : o.audioKbps
                let pcm: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: canais, AVSampleRateKey: 48000]
                if veloz {
                    // muda o andamento sem mudar o tom
                    let mix = AVAssetReaderAudioMixOutput(audioTracks: [aUsar], audioSettings: pcm)
                    mix.audioTimePitchAlgorithm = .spectral
                    aOut = mix
                } else {
                    aOut = AVAssetReaderTrackOutput(track: atrack, outputSettings: pcm)
                }
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: canais,
                    AVSampleRateKey: 48000, AVEncoderBitRateKey: kbps * 1000])
            }
            if let aOut, let aIn, reader.canAdd(aOut), writer.canAdd(aIn) {
                aOut.alwaysCopiesSampleData = false
                reader.add(aOut); aIn.expectsMediaDataInRealTime = false; writer.add(aIn)
            } else { aOut = nil; aIn = nil }
        }

        var pares: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(vOut as AVAssetReaderOutput, vIn)]
        if let aOut, let aIn { pares.append((aOut, aIn)) }
        try await Bombeador.bombear(reader: reader, writer: writer,
                                    pares: pares,
                                    inicio: inicioSessao, duracao: CMTimeGetSeconds(duracaoSaida),
                                    cancel: cancel, progresso: progresso, quadro: duracaoDoQuadro(fps))
        return destino
    }

    /// Metadados do arquivo de saída: data (a do original ou a de agora), aparelho e, se pedido, localização.
    static func metadadosSaida(_ asset: AVAsset, o: OpcoesConversao) async -> [AVMetadataItem] {
        let fonte = (try? await asset.load(.metadata)) ?? []
        var itens: [AVMetadataItem] = []
        var manter: Set<AVMetadataIdentifier> = [.quickTimeMetadataMake, .quickTimeMetadataModel, .quickTimeMetadataSoftware]
        if o.manterLocalizacao { manter.insert(.quickTimeMetadataLocationISO6709) }
        for it in fonte {
            if let id = it.identifier, manter.contains(id) { itens.append(it) }
        }
        var data: Date?
        if o.usarDataAtual {
            data = Date()
        } else if let d = try? await asset.load(.creationDate), let v = try? await d.load(.dateValue) {
            data = v
        }
        if let data {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = .current
            let texto = f.string(from: data)
            for id in [AVMetadataIdentifier.quickTimeMetadataCreationDate, .commonIdentifierCreationDate] {
                let m = AVMutableMetadataItem()
                m.identifier = id
                m.value = texto as NSString
                m.dataType = kCMMetadataBaseDataType_UTF8 as String
                itens.append(m)
            }
        }
        return itens
    }

    /// Monta a composição que gira, enquadra e escala cada quadro para w×h.
    /// "Desfocado" usa o Core Image (fundo = o próprio quadro ampliado e desfocado);
    /// os outros modos só posicionam a camada (mais leve).
    static func composicao(fonte: AVAsset, trilha: AVAssetTrack, tam: CGSize, transf: CGAffineTransform, duracao: CMTime,
                           o: OpcoesConversao, w: Int, h: Int, fps: Double, cor: [String: String],
                           fpsGrade: Double? = nil,
                           tempoOriginal: (@Sendable (Double) -> Double)? = nil) async throws -> AVMutableVideoComposition {
        let exib = CGRect(origin: .zero, size: tam).applying(transf)
        let W = max(abs(exib.width), 1), H = max(abs(exib.height), 1)
        let cw = CGFloat(w), ch = CGFloat(h)
        let comp: AVMutableVideoComposition
        let desfocar = o.enquadramento?.modo == .desfocar
        let pintor = o.legenda.map { PintorLegenda(projeto: $0, tela: CGSize(width: w, height: h)) }
        if desfocar || pintor != nil {
            // Core Image: fundo desfocado e/ou legenda por cima do quadro
            let orient = orientacao(transf)
            let giraDeLado = orient == .left || orient == .right
            let enq = o.enquadramento
            comp = try await AVMutableVideoComposition.videoComposition(with: fonte) { req in
                let ext0 = req.sourceImage.extent
                // o quadro chega sem a rotação do vídeo; se já vier girado, não gira de novo
                let jaGirado = giraDeLado && abs(W - H) > 2 && abs(ext0.width - W) < 2 && abs(ext0.height - H) < 2
                let girado = jaGirado ? req.sourceImage : req.sourceImage.oriented(orient)
                let src = girado.transformed(by: CGAffineTransform(translationX: -girado.extent.minX, y: -girado.extent.minY))
                let sw = max(src.extent.width, 1), sh = max(src.extent.height, 1)
                let tela = CGRect(x: 0, y: 0, width: cw, height: ch)
                var quadro: CIImage
                if desfocar {
                    // frente: o vídeo inteiro, centrado
                    let s = min(cw / sw, ch / sh)
                    let frente = src.transformed(by: CGAffineTransform(scaleX: s, y: s))
                        .transformed(by: CGAffineTransform(translationX: (cw - sw * s) / 2, y: (ch - sh * s) / 2))
                    // fundo: ampliado para cobrir, desfocado em 1/8 do tamanho (leve) e escurecido um pouco
                    let sf = max(cw / sw, ch / sh)
                    let reducao: CGFloat = 8
                    let fundo = src.transformed(by: CGAffineTransform(scaleX: sf / reducao, y: sf / reducao))
                        .clampedToExtent()
                        .applyingGaussianBlur(sigma: Double(max(cw, ch) / reducao) * 0.035)
                        .transformed(by: CGAffineTransform(scaleX: reducao, y: reducao))
                        .transformed(by: CGAffineTransform(translationX: (cw - sw * sf) / 2, y: (ch - sh * sf) / 2))
                        .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.7])
                        .cropped(to: tela)
                    quadro = frente.composited(over: fundo)
                } else {
                    // o mesmo enquadramento da camada, no sistema do Core Image (origem embaixo)
                    var parte = CGRect(x: 0, y: 0, width: sw, height: sh)       // pedaço do quadro que vai para a saída
                    var destino = tela
                    switch enq?.modo {
                    case .preencher?, .livre?:
                        let r = enq!.recorte
                        let rw = max(1, CGFloat(r.largura) * sw), rh = max(1, CGFloat(r.altura) * sh)
                        parte = CGRect(x: CGFloat(r.x) * sw, y: sh - CGFloat(r.y) * sh - rh, width: rw, height: rh)
                    case .caber?:
                        let s = min(cw / sw, ch / sh)
                        destino = CGRect(x: (cw - sw * s) / 2, y: (ch - sh * s) / 2, width: sw * s, height: sh * s)
                    default: break
                    }
                    let sx = destino.width / parte.width, sy = destino.height / parte.height
                    var img = src.cropped(to: parte)
                        .transformed(by: CGAffineTransform(translationX: -parte.minX, y: -parte.minY))
                    if sy < 0.98 || sx < 0.98 {
                        // reduzindo: Lanczos (o redimensionamento comum do Core Image perde nitidez)
                        img = img.clampedToExtent()
                            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
                            .cropped(to: CGRect(x: 0, y: 0, width: destino.width, height: destino.height))
                    } else {
                        img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    }
                    img = img.transformed(by: CGAffineTransform(translationX: destino.minX, y: destino.minY))
                    quadro = img.composited(over: CIImage(color: .black).cropped(to: tela))
                }
                if let pintor {
                    let t = CMTimeGetSeconds(req.compositionTime)
                    if t.isFinite, let leg = pintor.imagem(em: tempoOriginal?(t) ?? t) { quadro = leg.composited(over: quadro) }
                }
                req.finish(with: quadro.cropped(to: tela), context: nil)
            }
        } else {
            // posição no espaço do quadro já girado (origem no canto de cima, à esquerda)
            let pos: CGAffineTransform
            switch o.enquadramento?.modo {
            case .preencher?, .livre?:
                let r = o.enquadramento!.recorte
                let rx = CGFloat(r.x) * W, ry = CGFloat(r.y) * H
                let rw = max(1, CGFloat(r.largura) * W), rh = max(1, CGFloat(r.altura) * H)
                pos = CGAffineTransform(translationX: -rx, y: -ry).concatenating(CGAffineTransform(scaleX: cw / rw, y: ch / rh))
            case .caber?:
                let s = min(cw / W, ch / H)
                pos = CGAffineTransform(scaleX: s, y: s)
                    .concatenating(CGAffineTransform(translationX: (cw - W * s) / 2, y: (ch - H * s) / 2))
            default:
                // escala por eixo: w/h foram arredondados para par, então uma escala única
                // deixaria sobra/corte de ~1 px numa das bordas
                pos = CGAffineTransform(scaleX: cw / W, y: ch / H)
            }
            let t = transf
                .concatenating(CGAffineTransform(translationX: -exib.minX, y: -exib.minY))
                .concatenating(pos)
            comp = AVMutableVideoComposition()
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: duracao)
            let camada = AVMutableVideoCompositionLayerInstruction(assetTrack: trilha)
            camada.setTransform(t, at: .zero)
            instr.layerInstructions = [camada]
            comp.instructions = [instr]
        }
        comp.renderSize = CGSize(width: w, height: h)
        if let fpsGrade {
            // tempo dos quadros = o da própria trilha; a grade (2× a fonte) só vale se o sistema ignorar isso
            comp.sourceTrackIDForFrameTiming = trilha.trackID
            comp.frameDuration = duracaoDoQuadro(fpsGrade)
        } else {
            comp.frameDuration = duracaoDoQuadro(fps)
        }
        comp.colorPrimaries = cor[AVVideoColorPrimariesKey]
        comp.colorTransferFunction = cor[AVVideoTransferFunctionKey]
        comp.colorYCbCrMatrix = cor[AVVideoYCbCrMatrixKey]
        return comp
    }

    /// Do tempo da composição para o tempo do vídeo original (a legenda usa o relógio do original).
    static func relogio(inicio: Double, velocidade: Double?) -> @Sendable (Double) -> Double {
        guard let velocidade else { return { $0 } }
        return { inicio + $0 * velocidade }
    }

    /// Rotação do vídeo (preferredTransform) como orientação de imagem, para o Core Image.
    static func orientacao(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        func q(_ v: CGFloat) -> Int { Int(v.rounded()) }
        switch (q(t.a), q(t.b), q(t.c), q(t.d)) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        default: return .up
        }
    }

    static func duracaoDoQuadro(_ fps: Double) -> CMTime {
        for (alvo, num, den) in [(23.976, 1001, 24000), (29.97, 1001, 30000), (59.94, 1001, 60000)] where abs(fps - alvo) < 0.02 {
            return CMTime(value: CMTimeValue(num), timescale: CMTimeScale(den))
        }
        let f = max(1, Int(fps.rounded()))
        return CMTime(value: 1, timescale: CMTimeScale(f))
    }

    static func coresDeSaida(_ info: InfoMidia, hdr: Bool) -> [String: String] {
        if hdr {
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: info.hdr == .pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }

    /// Monta os ajustes do codificador e confere com o AVAssetWriter antes de usar
    /// (ajuste não suportado derrubaria o app). Vai tirando os opcionais até servir.
    /// Mesmo texto da chave no CoreMedia (extensão do formato) e no VideoToolbox (propriedade do codificador).
    static let chaveAmbiente = "AmbientViewingEnvironment"

    static func ajustesVideo(_ writer: AVAssetWriter, o: OpcoesConversao, info: InfoMidia, w: Int, h: Int,
                             fps: Double, taxa: Double, hdr: Bool, cor: [String: String], ambiente: Data? = nil) throws -> [String: Any] {
        var comp: [String: Any] = [
            AVVideoAverageBitRateKey: Int(taxa),
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if o.codec == .h264 {
            comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            comp[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        } else {
            comp[AVVideoProfileLevelKey] = (hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
        }

        func montar(_ c: [String: Any]) -> [String: Any] {
            [AVVideoCodecKey: o.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
             AVVideoWidthKey: w, AVVideoHeightKey: h,
             AVVideoColorPropertiesKey: cor,
             AVVideoCompressionPropertiesKey: c]
        }
        // (o Dolby Vision não é pedido: a composição refaz os quadros e os metadados dele não
        // sobrevivem; uma chave que o codificador não aceite derrubaria o app)
        var tentativas: [[String: Any]] = []
        if let ambiente {
            var c = comp
            c[chaveAmbiente] = ambiente
            tentativas.append(c)
        }
        tentativas.append(comp)
        var basico = comp
        [AVVideoMaxKeyFrameIntervalDurationKey, AVVideoExpectedSourceFrameRateKey, AVVideoH264EntropyModeKey].forEach { basico.removeValue(forKey: $0) }
        tentativas.append(basico)
        for c in tentativas {
            let s = montar(c)
            if writer.canApply(outputSettings: s, forMediaType: .video) { return s }
        }
        throw ErroApp("O codificador do iPhone recusou esses ajustes (\(o.codec == .hevc ? "HEVC" : "H.264") \(w)×\(h)).")
    }
}

// MARK: - leitura → escrita

enum Bombeador {
    /// Passa as amostras de cada saída do leitor para a entrada do gravador, em paralelo.
    static func bombear(reader: AVAssetReader, writer: AVAssetWriter,
                        pares: [(AVAssetReaderOutput, AVAssetWriterInput)],
                        inicio: CMTime, duracao: Double, cancel: Cancelamento,
                        progresso: @escaping ConversorVideo.Progresso, quadro: CMTime? = nil) async throws {
        guard reader.startReading() else {
            throw ErroApp("Falha ao ler: \(reader.error?.localizedDescription ?? "desconhecida")")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ErroApp("Falha ao gravar: \(writer.error?.localizedDescription ?? "desconhecida")")
        }
        writer.startSession(atSourceTime: inicio)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let grupo = DispatchGroup()
            for (k, (saida, entrada)) in pares.enumerated() {
                grupo.enter()
                let fila = DispatchQueue(label: "estudio.bombear.\(k)")
                let fim = Terminou()
                // vídeo (par 0) com `quadro`: os quadros vão para a grade de fps constante
                let grade = (k == 0 && quadro != nil) ? Grade(quadro: quadro!, inicio: inicio) : nil
                entrada.requestMediaDataWhenReady(on: fila) {
                    while entrada.isReadyForMoreMediaData && !fim.valor {
                        // só falha/cancelamento: o leitor pode virar .completed quando uma saída
                        // termina, e a outra ainda tem amostras no buffer (cortaria o fim do áudio)
                        if cancel.cancelado || reader.status == .failed || reader.status == .cancelled {
                            entrada.markAsFinished(); fim.valor = true; grupo.leave(); return
                        }
                        let amostra: CMSampleBuffer
                        if let grade, !grade.fila.isEmpty {
                            amostra = grade.fila.removeFirst()
                        } else {
                            guard let lida = saida.copyNextSampleBuffer() else {
                                entrada.markAsFinished(); fim.valor = true; grupo.leave(); return
                            }
                            if let grade {
                                grade.receber(lida)
                                if grade.fila.isEmpty { continue }        // quadro que sobrou (fps menor que o da fonte)
                                amostra = grade.fila.removeFirst()
                            } else {
                                amostra = lida
                            }
                        }
                        if k == 0, duracao > 0 {
                            let t = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(amostra), inicio))
                            // avisa a cada 0,5% (um aviso por quadro inundaria o ator principal)
                            if t.isFinite {
                                let p = min(1, max(0, t / duracao))
                                if p - fim.ultimo >= 0.005 { fim.ultimo = p; progresso(p) }
                            }
                        }
                        if !entrada.append(amostra) {
                            entrada.markAsFinished(); fim.valor = true; grupo.leave(); return
                        }
                    }
                }
            }
            grupo.notify(queue: .global()) { cont.resume() }
        }

        if cancel.cancelado {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw CancellationError()
        }
        if reader.status == .failed || writer.status == .failed {
            let erro = writer.error ?? reader.error
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw ErroApp("A conversão falhou: \(erro?.localizedDescription ?? "erro desconhecido")")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ErroApp("Não consegui finalizar o arquivo: \(writer.error?.localizedDescription ?? "?")")
        }
        progresso(1)
    }

    final class Terminou: @unchecked Sendable { var valor = false; var ultimo = -1.0 }

    /// Põe os quadros lidos numa grade de fps constante. Cada quadro vai para o instante da grade
    /// mais próximo do tempo dele (tolerância de 1/4 de quadro para trás, o que absorve tempos
    /// arredondados); quadro que cai num instante já ocupado é descartado (fps de saída menor);
    /// instante sem quadro (fps variável) repete o anterior.
    final class Grade: @unchecked Sendable {
        let quadro: CMTime
        let inicio: CMTime
        var proximo: Int64 = 0
        var anterior: CMSampleBuffer?
        var fila: [CMSampleBuffer] = []

        init(quadro: CMTime, inicio: CMTime) { self.quadro = quadro; self.inicio = inicio }

        func receber(_ a: CMSampleBuffer) {
            let p = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(a), inicio))
            let q = CMTimeGetSeconds(quadro)
            guard p.isFinite, q.isFinite, q > 0 else { fila.append(a); return }
            var k = Int64((p / q + 0.25).rounded(.down))
            if anterior == nil { k = max(0, k) }
            if k < proximo { return }
            if let ant = anterior {
                while proximo < k, let c = copia(ant, proximo) { fila.append(c); proximo += 1 }
            }
            guard let c = copia(a, k) else { return }
            fila.append(c)
            proximo = k + 1
            anterior = a
        }

        private func copia(_ a: CMSampleBuffer, _ k: Int64) -> CMSampleBuffer? {
            var t = CMSampleTimingInfo(duration: quadro,
                                       presentationTimeStamp: CMTimeAdd(inicio, CMTimeMultiply(quadro, multiplier: Int32(clamping: k))),
                                       decodeTimeStamp: .invalid)
            var saida: CMSampleBuffer?
            let r = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: a,
                                                          sampleTimingEntryCount: 1, sampleTimingArray: &t,
                                                          sampleBufferOut: &saida)
            return r == noErr ? saida : nil
        }
    }
}


// MARK: - velocidade

enum Velocidade {
    static let opcoes: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    static func nome(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_BR"); f.minimumFractionDigits = 0; f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + "×"
    }

    /// Composição só com o trecho escolhido, com o tempo escalado para a velocidade pedida.
    static func composicao(_ asset: AVAsset, faixa: CMTimeRange, velocidade: Double, comVideo: Bool) async throws
        -> (AVMutableComposition, AVMutableCompositionTrack?, AVMutableCompositionTrack?) {
        let comp = AVMutableComposition()
        var cv: AVMutableCompositionTrack?
        var ca: AVMutableCompositionTrack?
        var videos: [AVAssetTrack] = []
        if comVideo { videos = try await asset.loadTracks(withMediaType: .video) }
        // cada trilha entra só com a parte que existe dentro do trecho (pedir além do fim
        // da trilha faz o insertTimeRange falhar), na mesma posição relativa ao início do trecho
        func inserir(_ origem: AVAssetTrack, em destino: AVMutableCompositionTrack?) async throws {
            let existe = try await origem.load(.timeRange)
            let r = CMTimeRangeGetIntersection(faixa, otherRange: existe)
            guard CMTimeCompare(r.duration, .zero) > 0 else { return }
            try destino?.insertTimeRange(r, of: origem, at: CMTimeSubtract(r.start, faixa.start))
        }
        if let v = videos.first {
            cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try await inserir(v, em: cv)
            cv?.preferredTransform = try await v.load(.preferredTransform)
        }
        let audios = try await asset.loadTracks(withMediaType: .audio)
        if let a = audios.first {
            ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try await inserir(a, em: ca)
        }
        let dur = comp.duration
        guard CMTimeCompare(dur, .zero) > 0 else { throw ErroApp("O trecho escolhido está vazio.") }
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: dur),
                            toDuration: CMTimeMultiplyByFloat64(dur, multiplier: 1.0 / max(0.1, velocidade)))
        return (comp, cv, ca)
    }
}
