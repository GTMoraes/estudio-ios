import Foundation
import AVFoundation
import CoreMedia

/// Informações de um vídeo para a tela de detalhes (estilo do "i" do app Fotos).
struct DetalhesVideo {
    var info = InfoMidia()
    var taxaVideo: Double = 0        // bits/s
    var taxaAudio: Double = 0
    var data: Date?
    var camera: String?
    var local = false
    var ambienteLux: Double?

    static func ler(_ url: URL) async -> DetalhesVideo? {
        guard let i = try? await InfoMidia.ler(url) else { return nil }
        var d = DetalhesVideo(info: i)
        let asset = AVURLAsset(url: url)
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            d.taxaVideo = Double((try? await v.load(.estimatedDataRate)) ?? 0)
        }
        if let a = try? await asset.loadTracks(withMediaType: .audio).first {
            d.taxaAudio = Double((try? await a.load(.estimatedDataRate)) ?? 0)
        }
        if let c = try? await asset.load(.creationDate), let v = try? await c.load(.dateValue) { d.data = v }
        let meta = (try? await asset.load(.metadata)) ?? []
        func texto(_ id: AVMetadataIdentifier) async -> String? {
            guard let it = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first else { return nil }
            return try? await it.load(.stringValue)
        }
        let marca = await texto(.quickTimeMetadataMake) ?? ""
        let modelo = await texto(.quickTimeMetadataModel) ?? ""
        let cam = modelo.lowercased().hasPrefix(marca.lowercased()) ? modelo : [marca, modelo].filter { !$0.isEmpty }.joined(separator: " ")
        d.camera = cam.isEmpty ? nil : cam
        d.local = !AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .quickTimeMetadataLocationISO6709).isEmpty
            || !AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierLocation).isEmpty
        d.ambienteLux = await ambienteLux(url)
        return d
    }

    /// Luz do ambiente gravada no vídeo HDR (caixa amve: iluminância em 0,0001 lux, big-endian).
    static func ambienteLux(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let v = try? await asset.loadTracks(withMediaType: .video).first,
              let fd = try? await v.load(.formatDescriptions).first,
              let dados = CMFormatDescriptionGetExtension(fd, extensionKey: ConversorVideo.chaveAmbiente as CFString) as? Data,
              dados.count >= 4 else { return nil }
        let b = [UInt8](dados.prefix(4))
        let valor = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        return Double(valor) / 10_000
    }
}
