import Foundation
import ImageIO
import UniformTypeIdentifiers
import Accelerate
import CoreGraphics

/// Conversão de imagens: a aba de imagem do ConversorMidia (Nucleo/Imagem.cs + MotorImagem.cs),
/// feita com o ImageIO do iOS e o vImage (Lanczos). WebP pela libwebp compilada no app.

enum FormatoImagem: String, Codable, CaseIterable, Identifiable {
    case webp, jpg, heic, png, avif, manter
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .webp: return "WEBP"
        case .jpg: return "JPG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        case .avif: return "AVIF"
        case .manter: return "Manter o original"
        }
    }
    var extensao: String? {
        switch self {
        case .webp: return "webp"
        case .jpg: return "jpg"
        case .heic: return "heic"
        case .png: return "png"
        case .avif: return "avif"
        case .manter: return nil
        }
    }
    var comPerdas: Bool { self == .webp || self == .jpg || self == .heic || self == .avif }
    var uti: String? {
        switch self {
        case .jpg: return UTType.jpeg.identifier
        case .heic: return UTType.heic.identifier
        case .png: return UTType.png.identifier
        case .avif: return "public.avif"
        default: return nil
        }
    }
}

enum ModoRedimensionar: String, Codable, CaseIterable, Identifiable {
    case nenhum, ladoMaior, caixa, porcentagem
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .nenhum: return "Não redimensionar"
        case .ladoMaior: return "Lado maior"
        case .caixa: return "Caber em largura × altura"
        case .porcentagem: return "Porcentagem"
        }
    }
}

enum ModoMetadados: String, Codable, CaseIterable, Identifiable {
    case essencial, tudo, nenhum
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .essencial: return "Só o essencial (sem GPS)"
        case .tudo: return "Manter tudo"
        case .nenhum: return "Remover tudo"
        }
    }
}

/// Recorte relativo (0…1) sobre a imagem já girada pela orientação do EXIF.
struct Recorte: Codable, Equatable {
    var x = 0.0, y = 0.0, largura = 1.0, altura = 1.0
}

struct OpcoesImagem: Codable, Equatable {
    var formato: FormatoImagem = .webp
    var qualidade = 80                   // 1…100 (jpg/webp/heic/avif)
    var semPerdas = false                // webp
    var usarAlvo = false
    var alvoKB = 200

    var redimensionar: ModoRedimensionar = .nenhum
    var ladoMaior = 1920
    var larguraMax = 1920
    var alturaMax = 1080
    var porcentagem = 50.0
    var nuncaAumentar = true

    var recorte: Recorte?
    var proporcaoRecorte = 0.0           // 0 = livre; senão largura/altura

    var metadados: ModoMetadados = .essencial
    var tirarGPS = true
    var paraSRGB = true
    /// nil/false = mantém a data da foto; true = grava a data e hora da conversão
    /// (opcional para os presets e ajustes já gravados continuarem abrindo)
    var dataAgora: Bool?
    var usarDataAtual: Bool {
        get { dataAgora ?? false }
        set { dataAgora = newValue }
    }

    var padraoNome = "{nome}"
    var digitosContador = 3
}

/// Contas de tamanho e corte (Geometria do ConversorMidia).
enum GeometriaImagem {
    static func redimensionar(_ l: Int, _ a: Int, _ o: OpcoesImagem) -> (Int, Int) {
        guard l > 0, a > 0 else { return (l, a) }
        var escala: Double
        switch o.redimensionar {
        case .ladoMaior: escala = Double(o.ladoMaior) / Double(max(l, a))
        case .caixa: escala = min(Double(o.larguraMax) / Double(l), Double(o.alturaMax) / Double(a))
        case .porcentagem: escala = o.porcentagem / 100
        case .nenhum: return (l, a)
        }
        if o.nuncaAumentar && escala > 1 { escala = 1 }
        return (max(1, Int((Double(l) * escala).rounded())), max(1, Int((Double(a) * escala).rounded())))
    }

    static func corte(_ l: Int, _ a: Int, _ r: Recorte) -> (x: Int, y: Int, l: Int, a: Int) {
        var x = Int((r.x * Double(l)).rounded()), y = Int((r.y * Double(a)).rounded())
        var cl = Int((r.largura * Double(l)).rounded()), ca = Int((r.altura * Double(a)).rounded())
        x = max(0, min(x, l - 1)); y = max(0, min(y, a - 1))
        cl = max(1, min(cl, l - x)); ca = max(1, min(ca, a - y))
        return (x, y, cl, ca)
    }

    /// Tamanho final (depois de corte e redimensionamento) para uma imagem de l×a já girada.
    static func tamanhoFinal(_ l: Int, _ a: Int, _ o: OpcoesImagem) -> (Int, Int) {
        var (w, h) = (l, a)
        if let r = o.recorte { let c = corte(l, a, r); (w, h) = (c.l, c.a) }
        return redimensionar(w, h, o)
    }
}

/// Busca de qualidade para caber num alvo de tamanho (BuscaQualidade do ConversorMidia).
struct BuscaQualidade {
    var min = 30, max = 95, tentativas = 0, maxTentativas = 7
    let alvo: Int
    private(set) var atual: Int
    private(set) var melhor = -1

    init(alvo: Int) { self.alvo = alvo; atual = (30 + 95) / 2 }

    mutating func registrar(_ bytes: Int) -> Bool {
        tentativas += 1
        if bytes <= alvo && atual > melhor { melhor = atual }
        if bytes > alvo { max = atual - 1 } else { min = atual + 1 }
        if min > max || tentativas >= maxTentativas { return false }
        atual = (min + max) / 2
        return true
    }
}

enum Renomear {
    /// Tokens: {nome} {n} {largura} {altura} {data} {datahora}. Sem largura/altura, esses tokens somem.
    static func aplicar(_ padrao: String, nome: String, indice: Int = 1, largura: Int? = nil, altura: Int? = nil,
                        data: Date, digitos: Int = 3) -> String {
        var s = padrao.trimmingCharacters(in: .whitespaces).isEmpty ? "{nome}" : padrao
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        s = s.replacingOccurrences(of: "{nome}", with: nome)
        s = s.replacingOccurrences(of: "{n}", with: String(format: "%0\(max(1, digitos))d", indice))
        s = s.replacingOccurrences(of: "{largura}", with: largura.map(String.init) ?? "")
        s = s.replacingOccurrences(of: "{altura}", with: altura.map(String.init) ?? "")
        f.dateFormat = "yyyy-MM-dd"; s = s.replacingOccurrences(of: "{data}", with: f.string(from: data))
        f.dateFormat = "yyyy-MM-dd_HH-mm"; s = s.replacingOccurrences(of: "{datahora}", with: f.string(from: data))
        let proibidos = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        s = s.components(separatedBy: proibidos).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "arquivo" : s
    }

    static let padrao = "{nome}"
}

struct DetalhesImagem {
    var largura: Int, altura: Int
    var bytes: Int64 = 0
    var tipo: String?
    var data: Date?
    var camera: String?
    var lente: String?
    var exposicao: String?
    var perfil: String?
    var alfa = false
    var gps = false
    var quadros = 1                 // animação (GIF / WebP animado)
    var duracao: Double?
}

struct InfoImagem {
    let largura: Int          // já girada
    let altura: Int
    let tipo: String?         // UTI do original
    let data: Date
}

enum ConversorImagem {
    /// Formatos que este iPhone sabe gravar (AVIF depende da versão do iOS).
    static let formatosDisponiveis: [FormatoImagem] = {
        let tipos = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return FormatoImagem.allCases.filter { f in
            switch f {
            case .heic: return tipos.contains(UTType.heic.identifier)
            case .avif: return tipos.contains("public.avif")
            default: return true
            }
        }
    }()

    static func info(_ url: URL) -> InfoImagem? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let l = p[kCGImagePropertyPixelWidth] as? Int, let a = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let girada = o >= 5 && o <= 8
        return InfoImagem(largura: girada ? a : l, altura: girada ? l : a,
                          tipo: CGImageSourceGetType(src) as String?, data: dataDa(p, url))
    }

    private static func dataDa(_ p: [CFString: Any], _ url: URL) -> Date {
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: s) { return d }
        }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? Date()
    }

    /// Miniatura já girada (para as telas).
    static func miniatura(_ url: URL, lado: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: lado,
        ] as CFDictionary)
    }

    /// Tudo o que a tela de detalhes mostra (estilo do "i" do app Fotos).
    static func detalhes(_ url: URL) -> DetalhesImagem? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let l = p[kCGImagePropertyPixelWidth] as? Int, let a = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let girada = o >= 5 && o <= 8
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var d = DetalhesImagem(largura: girada ? a : l, altura: girada ? l : a)
        d.bytes = Int64(((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0)
        d.tipo = CGImageSourceGetType(src) as String?
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let s = (exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime]) as? String {
            d.data = f.date(from: s)
        }
        let marca = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let modelo = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let cam = modelo.lowercased().hasPrefix(marca.lowercased()) ? modelo : [marca, modelo].filter { !$0.isEmpty }.joined(separator: " ")
        d.camera = cam.isEmpty ? nil : cam
        d.lente = exif[kCGImagePropertyExifLensModel] as? String
        var ex: [String] = []
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { ex.append("ISO \(iso)") }
        if let mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int { ex.append("\(mm) mm") }
        else if let mm = exif[kCGImagePropertyExifFocalLength] as? Double { ex.append(String(format: "%.1f mm", mm)) }
        if let fn = exif[kCGImagePropertyExifFNumber] as? Double {
            let nf = NumberFormatter(); nf.maximumFractionDigits = 2; nf.minimumFractionDigits = 0
            ex.append("ƒ" + (nf.string(from: NSNumber(value: fn)) ?? String(fn)))
        }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            ex.append(t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t))
        }
        d.exposicao = ex.isEmpty ? nil : ex.joined(separator: " · ")
        d.perfil = p[kCGImagePropertyProfileName] as? String
        d.alfa = (p[kCGImagePropertyHasAlpha] as? Bool) ?? false
        d.gps = p[kCGImagePropertyGPSDictionary] != nil
        d.quadros = CGImageSourceGetCount(src)
        if d.quadros > 1 { d.duracao = animacao(src)?.duracao }
        return d
    }

    /// Quadros de uma animação (GIF / WebP animado), já reduzidos para a tela, e a duração total.
    static func animacao(_ src: CGImageSource, lado: Int? = nil, maxQuadros: Int = 600) -> (quadros: [CGImage], duracao: Double)? {
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return nil }
        var quadros: [CGImage] = []
        var total = 0.0
        for i in 0..<min(n, maxQuadros) {
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
            let dic = (p[kCGImagePropertyGIFDictionary] ?? p[kCGImagePropertyWebPDictionary]) as? [CFString: Any] ?? [:]
            var atraso = (dic[kCGImagePropertyGIFUnclampedDelayTime] ?? dic[kCGImagePropertyWebPUnclampedDelayTime]) as? Double ?? 0
            if atraso <= 0.001 { atraso = (dic[kCGImagePropertyGIFDelayTime] ?? dic[kCGImagePropertyWebPDelayTime]) as? Double ?? 0.1 }
            total += max(0.02, atraso)
            if let lado {
                if let img = CGImageSourceCreateThumbnailAtIndex(src, i, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: lado,
                ] as CFDictionary) { quadros.append(img) }
            }
        }
        return (quadros, total)
    }

    /// Nome curto do formato a partir do UTI ("public.heic" -> "HEIC").
    static func nomeFormato(_ uti: String?) -> String {
        guard let uti else { return "—" }
        if uti == "org.webmproject.webp" { return "WEBP" }
        return (UTType(uti)?.preferredFilenameExtension ?? uti.components(separatedBy: ".").last ?? uti).uppercased()
    }

    /// Formato de saída efetivo ("manter" vira o formato do original, quando dá para gravar).
    static func formatoFinal(_ o: OpcoesImagem, tipoOriginal: String?) -> FormatoImagem {
        guard o.formato == .manter else { return o.formato }
        let t = tipoOriginal.flatMap { UTType($0) }
        if t?.conforms(to: .png) == true { return .png }
        if t?.conforms(to: .heic) == true || t?.conforms(to: .heif) == true {
            return formatosDisponiveis.contains(.heic) ? .heic : .jpg
        }
        if t?.identifier == "org.webmproject.webp" { return .webp }
        if t?.identifier == "public.avif" { return formatosDisponiveis.contains(.avif) ? .avif : .jpg }
        return .jpg
    }

    /// Converte uma imagem e grava em `destino` (a extensão já vem certa). Devolve o tamanho gravado.
    @discardableResult
    static func converter(_ url: URL, _ o: OpcoesImagem, destino: URL) throws -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let lOrig = props[kCGImagePropertyPixelWidth] as? Int, let aOrig = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ErroApp("Não consegui ler a imagem \(url.lastPathComponent).") }
        let formato = formatoFinal(o, tipoOriginal: CGImageSourceGetType(src) as String?)

        // 1. decodifica já girada pela orientação do EXIF, no tamanho original (sem reamostrar)
        guard let girada = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(lOrig, aOrig),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw ErroApp("Não consegui decodificar \(url.lastPathComponent).") }

        // 2. desenha em RGBA 8 bits no espaço de cor final (P3 do iPhone -> sRGB, se pedido)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let espaco: CGColorSpace = {
            if o.paraSRGB { return srgb }
            if let c = girada.colorSpace, c.model == .rgb { return c }
            return srgb
        }()
        let alfaOriginal: Bool = {
            switch girada.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        let comAlfa = alfaOriginal && formato != .jpg
        let (W, H) = (girada.width, girada.height)
        var base = try Buffer(largura: W, altura: H)
        guard let ctx = CGContext(data: base.dados, width: W, height: H, bitsPerComponent: 8, bytesPerRow: base.passo,
                                  space: espaco, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ErroApp("Sem memória para a imagem \(url.lastPathComponent).")
        }
        ctx.interpolationQuality = .high
        if !comAlfa {       // JPG não tem transparência: fundo branco, como o ConversorMidia
            ctx.setFillColor(CGColor(colorSpace: espaco, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        ctx.draw(girada, in: CGRect(x: 0, y: 0, width: W, height: H))

        // 3. corte
        var (x0, y0, cw, ch) = (0, 0, W, H)
        if let r = o.recorte { let c = GeometriaImagem.corte(W, H, r); (x0, y0, cw, ch) = (c.x, c.y, c.l, c.a) }
        var fonte = vImage_Buffer(data: base.dados.advanced(by: y0 * base.passo + x0 * 4), height: vImagePixelCount(ch),
                                  width: vImagePixelCount(cw), rowBytes: base.passo)

        // 4. redimensiona (Lanczos do vImage, como o filtro Lanczos do ConversorMidia)
        let (fw, fh) = GeometriaImagem.redimensionar(cw, ch, o)
        var pronta: Buffer
        if fw != cw || fh != ch {
            pronta = try Buffer(largura: fw, altura: fh)
            var dst = pronta.vimage
            let erro = vImageScale_ARGB8888(&fonte, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            guard erro == kvImageNoError else { throw ErroApp("Falha ao redimensionar (\(erro)).") }
        } else if x0 != 0 || y0 != 0 || cw != W || ch != H {
            pronta = try Buffer(largura: cw, altura: ch)
            var dst = pronta.vimage
            vImageCopyBuffer(&fonte, &dst, 4, vImage_Flags(kvImageNoFlags))
        } else {
            pronta = base
        }
        if pronta.dados != base.dados { base.liberar() }
        defer { pronta.liberar() }

        // 5. metadados
        let meta = metadados(props, o)

        // 6. grava (com busca de qualidade quando há alvo de tamanho)
        func codificar(_ q: Int) throws -> Data {
            if formato == .webp {
                return try webp(pronta, comAlfa: comAlfa, espaco: espaco, qualidade: q, semPerdas: o.semPerdas, meta: meta)
            }
            return try imageIO(pronta, comAlfa: comAlfa, espaco: espaco, formato: formato, qualidade: q, meta: meta)
        }
        var dados: Data
        if o.usarAlvo && formato.comPerdas && !(formato == .webp && o.semPerdas) {
            var busca = BuscaQualidade(alvo: o.alvoKB * 1024)
            var melhor: Data?
            while true {
                let d = try codificar(busca.atual)
                if d.count <= busca.alvo && busca.atual > busca.melhor { melhor = d }
                if !busca.registrar(d.count) { break }
            }
            // nada coube: usa a qualidade mais baixa da busca, como o ConversorMidia
            dados = try melhor ?? codificar(30)
        } else {
            dados = try codificar(o.qualidade)
        }
        try dados.write(to: destino, options: .atomic)
        return dados.count
    }

    // MARK: - metadados

    /// Data no formato do EXIF ("2026:09:30 14:05:00") e o fuso ("-03:00").
    static func textoExif(_ d: Date) -> (data: String, fuso: String) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let seg = TimeZone.current.secondsFromGMT(for: d)
        let fuso = String(format: "%@%02d:%02d", seg < 0 ? "-" : "+", abs(seg) / 3600, (abs(seg) % 3600) / 60)
        return (f.string(from: d), fuso)
    }

    private static func metadados(_ p: [CFString: Any], _ o: OpcoesImagem) -> [CFString: Any] {
        let agora = o.usarDataAtual ? textoExif(Date()) : nil
        switch o.metadados {
        case .nenhum:
            return [:]
        case .essencial:
            // só a data (a orientação já foi aplicada nos pixels)
            if let agora {
                return [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: agora.data,
                                                         kCGImagePropertyExifDateTimeDigitized: agora.data,
                                                         kCGImagePropertyExifOffsetTimeOriginal: agora.fuso,
                                                         kCGImagePropertyExifOffsetTimeDigitized: agora.fuso] as [CFString: Any]]
            }
            guard let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any],
                  let d = exif[kCGImagePropertyExifDateTimeOriginal] else { return [:] }
            var e: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: d]
            if let f = exif[kCGImagePropertyExifOffsetTimeOriginal] { e[kCGImagePropertyExifOffsetTimeOriginal] = f }
            return [kCGImagePropertyExifDictionary: e]
        case .tudo:
            var m = p
            for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyColorModel,
                      kCGImagePropertyDepth, kCGImagePropertyProfileName, kCGImagePropertyHasAlpha,
                      kCGImagePropertyOrientation, kCGImagePropertyFileSize, kCGImagePropertyPrimaryImage] {
                m.removeValue(forKey: k)
            }
            if var tiff = m[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                m[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = m[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                if let agora {
                    for k in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized] { exif[k] = agora.data }
                    for k in [kCGImagePropertyExifOffsetTime, kCGImagePropertyExifOffsetTimeOriginal,
                              kCGImagePropertyExifOffsetTimeDigitized] { exif[k] = agora.fuso }
                    for k in [kCGImagePropertyExifSubsecTime, kCGImagePropertyExifSubsecTimeOriginal,
                              kCGImagePropertyExifSubsecTimeDigitized] { exif.removeValue(forKey: k) }
                }
                m[kCGImagePropertyExifDictionary] = exif
            }
            if let agora {
                if var tiff = m[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFDateTime] = agora.data
                    m[kCGImagePropertyTIFFDictionary] = tiff
                }
                if var iptc = m[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
                    for k in [kCGImagePropertyIPTCDateCreated, kCGImagePropertyIPTCTimeCreated,
                              kCGImagePropertyIPTCDigitalCreationDate, kCGImagePropertyIPTCDigitalCreationTime] {
                        iptc.removeValue(forKey: k)
                    }
                    m[kCGImagePropertyIPTCDictionary] = iptc
                }
            }
            if o.tirarGPS { m.removeValue(forKey: kCGImagePropertyGPSDictionary) }
            m[kCGImagePropertyOrientation] = 1
            return m
        }
    }

    // MARK: - codificadores

    private static func cgImage(_ b: Buffer, comAlfa: Bool, espaco: CGColorSpace) throws -> CGImage {
        let info = comAlfa ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let prov = CGDataProvider(dataInfo: nil, data: b.dados, size: b.passo * b.altura, releaseData: { _, _, _ in }),
              let img = CGImage(width: b.largura, height: b.altura, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: b.passo,
                                space: espaco, bitmapInfo: CGBitmapInfo(rawValue: info), provider: prov, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent)
        else { throw ErroApp("Falha ao montar a imagem final.") }
        return img
    }

    private static func imageIO(_ b: Buffer, comAlfa: Bool, espaco: CGColorSpace, formato: FormatoImagem,
                                qualidade: Int, meta: [CFString: Any]) throws -> Data {
        guard let uti = formato.uti else { throw ErroApp("Formato sem gravador.") }
        let img = try cgImage(b, comAlfa: comAlfa, espaco: espaco)
        let dados = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(dados, uti as CFString, 1, nil) else {
            throw ErroApp("Este iPhone não grava \(formato.nome).")
        }
        var p = meta
        if formato.comPerdas { p[kCGImageDestinationLossyCompressionQuality] = Double(qualidade) / 100 }
        CGImageDestinationAddImage(dest, img, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ErroApp("Falha ao gravar \(formato.nome).") }
        return dados as Data
    }

    private static func webp(_ b: Buffer, comAlfa: Bool, espaco: CGColorSpace, qualidade: Int, semPerdas: Bool,
                             meta: [CFString: Any]) throws -> Data {
        // a libwebp quer RGBA sem pré-multiplicar
        var rgba = b
        var copia: Buffer?
        if comAlfa {
            let c = try Buffer(largura: b.largura, altura: b.altura)
            var s = b.vimage, d = c.vimage
            vImageUnpremultiplyData_RGBA8888(&s, &d, vImage_Flags(kvImageNoFlags))
            rgba = c; copia = c
        }
        defer { copia?.liberar() }
        let exif = meta.isEmpty ? nil : blocoExif(meta)
        // ICC só quando não é sRGB (sem perfil, o WebP é lido como sRGB)
        let icc: Data? = (espaco.name == CGColorSpace.sRGB) ? nil : (espaco.copyICCData() as Data?)
        var saida: UnsafeMutablePointer<UInt8>?
        var tam = 0
        let px = rgba.dados.assumingMemoryBound(to: UInt8.self)
        let r: Int32 = (exif ?? Data()).withUnsafeBytes { e in
                (icc ?? Data()).withUnsafeBytes { i in
                    cod_webp(px, Int32(rgba.largura), Int32(rgba.altura), Int32(rgba.passo), comAlfa ? 1 : 0,
                             Float(qualidade), semPerdas ? 1 : 0,
                             e.baseAddress?.assumingMemoryBound(to: UInt8.self), exif?.count ?? 0,
                             i.baseAddress?.assumingMemoryBound(to: UInt8.self), icc?.count ?? 0,
                             &saida, &tam)
                }
        }
        guard r == 0, let saida else { throw ErroApp("Falha ao gravar WebP (\(r)).") }
        defer { cod_webp_liberar(saida) }
        return Data(bytes: saida, count: tam)
    }

    /// Bloco EXIF (TIFF) com os metadados pedidos, para o WebP: o ImageIO grava um JPEG
    /// minúsculo com eles e o bloco é tirado do segmento APP1 ("Exif\0\0").
    private static func blocoExif(_ meta: [CFString: Any]) -> Data? {
        guard let b = try? Buffer(largura: 8, altura: 8), let img = try? cgImage(b, comAlfa: false, espaco: CGColorSpace(name: CGColorSpace.sRGB)!),
              let jpg = try? { () throws -> Data in
                  defer { var bb = b; bb.liberar() }
                  let d = NSMutableData()
                  guard let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { throw ErroApp("") }
                  CGImageDestinationAddImage(dest, img, meta as CFDictionary)
                  guard CGImageDestinationFinalize(dest) else { throw ErroApp("") }
                  return d as Data
              }() else { return nil }
        let bytes = [UInt8](jpg)
        var i = 2
        while i + 4 < bytes.count, bytes[i] == 0xFF {
            let marcador = bytes[i + 1]
            let tam = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marcador == 0xDA { break }                  // começo da imagem: não há mais cabeçalhos
            if marcador == 0xE1, tam > 8, i + 2 + tam <= bytes.count,
               bytes[i + 4] == 0x45, bytes[i + 5] == 0x78, bytes[i + 6] == 0x69, bytes[i + 7] == 0x66 {   // "Exif"
                return Data(bytes[(i + 10)..<(i + 2 + tam)])
            }
            i += 2 + tam
        }
        return nil
    }
}

/// Bitmap RGBA 8 bits alinhado, liberado à mão (fotos de 48 MP ocupam ~200 MB).
struct Buffer {
    let largura: Int, altura: Int, passo: Int
    let dados: UnsafeMutableRawPointer

    init(largura: Int, altura: Int) throws {
        self.largura = largura; self.altura = altura
        passo = (largura * 4 + 63) & ~63
        guard let p = calloc(passo * altura, 1) else { throw ErroApp("Sem memória para a imagem.") }
        dados = p
    }
    var vimage: vImage_Buffer {
        vImage_Buffer(data: dados, height: vImagePixelCount(altura), width: vImagePixelCount(largura), rowBytes: passo)
    }
    mutating func liberar() { free(dados) }
}
