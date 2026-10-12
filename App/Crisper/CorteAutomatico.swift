import Foundation
import AVFoundation

/// A regra de corte aprovada no teste do GT-PC (arquivo "8-normal-v3"):
/// - tira os sons marcados ([UH], [throatclearing]…, menos risada), palavras cortadas ("esp-")
///   e repetições ("um um", "do do do", "que vamos que vamos"), olhando de novo depois de cada tirada;
/// - os pontos de corte só caem onde o som acabou: o fim de cada palavra é esticado até 50 ms de
///   silêncio (ou até o ponto mais baixo, se não houver), e o começo recua do mesmo jeito;
/// - pausas maiores que `juntar` viram um respiro de `pausa`.
enum CorteAutomatico {
    struct Trecho: Codable { var i: Double; var f: Double }

    static func normalizar(_ p: String) -> String {
        let s = p.lowercased().precomposedStringWithCanonicalMapping
        return String(s.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    }

    /// Quais palavras saem (índices).
    static func tiradas(_ w: [PalavraTempo]) -> Set<Int> {
        let n = w.map { normalizar($0.p) }
        var fora = Set<Int>()
        for (k, x) in w.enumerated() {
            let b = x.p.trimmingCharacters(in: .whitespacesAndNewlines)
            if (b.hasPrefix("[") && !b.lowercased().contains("laugh")) || b.hasSuffix("-") { fora.insert(k) }
        }
        var mudou = true
        while mudou {
            mudou = false
            let v = (0..<w.count).filter { !fora.contains($0) && !n[$0].isEmpty }
            guard v.count > 1 else { break }
            for j in 0..<(v.count - 1) {
                if n[v[j]] == n[v[j + 1]] { fora.insert(v[j]); mudou = true; break }
                if j + 3 < v.count && n[v[j]] == n[v[j + 2]] && n[v[j + 1]] == n[v[j + 3]] {
                    fora.insert(v[j]); fora.insert(v[j + 1]); mudou = true; break
                }
            }
        }
        return fora
    }

    /// Trechos a manter, em segundos. `audio`: 16 kHz mono.
    static func trechos(_ w: [PalavraTempo], audio: [Float], juntar: Double = 0.25, pausa: Double = 0.10) -> [Trecho] {
        let palavras = w.filter { $0.i != nil && $0.f != nil }
        guard !palavras.isEmpty else { return [] }
        // volume em quadros de 10 ms
        let H = 160
        let nq = audio.count / H
        guard nq > 0 else { return [] }
        var db = Array(repeating: Float(0), count: nq)
        for q in 0..<nq {
            var s: Float = 0
            for k in 0..<H { let v = audio[q * H + k]; s += v * v }
            db[q] = 20 * log10(sqrt(s / Float(H)) + 1e-9)
        }
        let ord = db.sorted()
        let x = 0.1 * Double(nq - 1)
        let lo = Int(x), hi = min(lo + 1, nq - 1)
        let piso = Double(ord[lo]) + Double(ord[hi] - ord[lo]) * (x - Double(lo))
        let quieto = db.map { Double($0) < piso + 10 }
        func q(_ t: Double) -> Int { min(nq - 1, max(0, Int(t * 100))) }
        func todosQuietos(_ a: Int, _ b: Int) -> Bool {      // [a, b)
            let a2 = max(0, a), b2 = min(nq, b)
            if a2 >= b2 { return true }
            for k in a2..<b2 where !quieto[k] { return false }
            return true
        }
        func minimo(_ a: Int, _ b: Int) -> Int {               // [a, b]
            var m = a
            for k in a...b where db[k] < db[m] { m = k }
            return m
        }
        func fimReal(_ t: Double, _ limite: Double) -> Double {
            var i = q(t)
            let L = q(min(limite, t + 0.7))
            while i < L {
                if todosQuietos(i, i + 5) { return Double(i) / 100 + 0.03 }
                i += 1
            }
            let j = L > q(t) ? minimo(q(t), L) : q(t)
            return Double(j) / 100
        }
        func iniReal(_ t: Double, _ limite: Double) -> Double {
            var i = q(t)
            let L = q(max(limite, t - 0.5))
            while i > L {
                if todosQuietos(i - 5, i) { return Double(i) / 100 - 0.03 }
                i -= 1
            }
            let j = q(t) > L ? minimo(L, q(t)) : q(t)
            return Double(j) / 100
        }

        let fora = tiradas(palavras)
        let dur = Double(audio.count) / 16000
        var seg: [(i: Double, f: Double, tiradaDepois: Bool)] = []
        for k in 0..<palavras.count where !fora.contains(k) {
            let p = palavras[k]
            let ant = k > 0 ? palavras[k - 1].f! : 0
            let prox = k + 1 < palavras.count ? palavras[k + 1].i! : dur
            let tiradaAntes = k > 0 && fora.contains(k - 1)
            let tiradaDepois = k + 1 < palavras.count && fora.contains(k + 1)
            var ini = iniReal(p.i!, ant), fim = fimReal(p.f!, prox)
            if tiradaAntes { ini = max(ini, ant) }
            if tiradaDepois { fim = min(fim, prox) }
            if let u = seg.last, ini - u.f <= juntar && !tiradaAntes {
                seg[seg.count - 1].f = max(u.f, fim)
                seg[seg.count - 1].tiradaDepois = tiradaDepois
            } else {
                if let u = seg.last, !u.tiradaDepois { seg[seg.count - 1].f = min(u.f + pausa, ini) }
                seg.append((ini, fim, tiradaDepois))
            }
        }
        return seg.map { Trecho(i: max(0, $0.i), f: min(dur, $0.f)) }.filter { $0.f > $0.i }
    }

    /// Grava só os trechos mantidos do áudio de `origem` (qualidade original, AAC), com 12 ms de
    /// fade em cada emenda para não estalar.
    static func gravar(origem: URL, trechos: [Trecho], destino: URL) async throws {
        let asset = AVURLAsset(url: origem)
        guard let faixa = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ErroApp("Esse arquivo não tem áudio.")
        }
        let comp = AVMutableComposition()
        guard let alvo = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ErroApp("Não consegui montar o áudio cortado.")
        }
        let escala: CMTimeScale = 48000
        var cursor = CMTime.zero
        let mix = AVMutableAudioMixInputParameters(track: alvo)
        let fade = CMTime(value: CMTimeValue(0.012 * Double(escala)), timescale: escala)
        for t in trechos {
            let ini = CMTime(seconds: t.i, preferredTimescale: escala)
            let dur = CMTime(seconds: t.f - t.i, preferredTimescale: escala)
            try alvo.insertTimeRange(CMTimeRange(start: ini, duration: dur), of: faixa, at: cursor)
            if dur > fade + fade {
                mix.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: cursor, duration: fade))
                mix.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: cursor + dur - fade, duration: fade))
            }
            cursor = cursor + dur
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [mix]
        guard let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw ErroApp("Não consegui gravar o áudio cortado.")
        }
        exp.audioMix = audioMix
        try? FileManager.default.removeItem(at: destino)
        try await exp.export(to: destino, as: .m4a)
    }
}
