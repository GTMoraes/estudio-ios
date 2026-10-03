import AVFoundation

/// O iPhone consegue abrir este vídeo? (VP9, por exemplo, ele não decodifica fora do Safari.)
enum Compatibilidade {
    /// Extensões de vídeo que o iPhone pode nem reconhecer como vídeo.
    private static let outrosVideos: Set<String> = ["webm", "mkv", "avi", "flv", "wmv", "ogv", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "rm", "rmvb", "asf", "divx", "f4v"]

    /// O nome do formato segundo o FFmpeg embutido (ex.: "VP9 em WEBM"); nil se nem ele abre ou se não há vídeo.
    private static func peloFFmpeg(_ url: URL) -> String? {
        var info = EstudioInfo()
        var erro = [CChar](repeating: 0, count: 128)
        guard let l = estudio_abrir(url.path, &info, &erro, 128) else { return nil }
        estudio_fechar(l)
        guard info.temVideo == 1 else { return nil }
        let codec = withUnsafeBytes(of: info.codecVideo) { b in
            String(decoding: b.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let ext = url.pathExtension.uppercased()
        return codec.isEmpty ? ext : codec.uppercased() + (ext.isEmpty ? "" : " em " + ext)
    }

    /// nil = abre. Senão, o nome do formato que o iPhone não abre (ex.: "VP9").
    static func problema(_ url: URL) async -> String? {
        guard ehVideoArquivo(url) || outrosVideos.contains(url.pathExtension.lowercased()) else { return nil }
        let asset = AVURLAsset(url: url)
        let trilhas: [AVAssetTrack]
        do { trilhas = try await asset.loadTracks(withMediaType: .video) }
        catch { return peloFFmpeg(url) ?? "não reconhecido" }      // o iPhone nem lê o arquivo (WebM, MKV…)
        guard let trilha = trilhas.first else {
            // sem imagem para o iPhone: só é problema se também não houver áudio
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            return audio.isEmpty ? (peloFFmpeg(url) ?? "não reconhecido") : nil
        }
        var codigo = ""
        if let d = ((try? await trilha.load(.formatDescriptions)) ?? []).first {
            let c = CMFormatDescriptionGetMediaSubType(d)
            let bytes = [UInt8((c >> 24) & 255), UInt8((c >> 16) & 255), UInt8((c >> 8) & 255), UInt8(c & 255)]
            codigo = String(bytes: bytes, encoding: .ascii)?.lowercased() ?? ""
        }
        let abre = (try? await trilha.load(.isDecodable)) ?? true
        let nuncaAbre = ["vp09", "vp08"].contains(codigo)
        if abre && !nuncaAbre { return nil }
        switch codigo {
        case "vp09": return "VP9"
        case "vp08": return "VP8"
        case "av01": return "AV1"
        default: return codigo.isEmpty ? "não reconhecido" : codigo.uppercased()
        }
    }
}
