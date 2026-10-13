import Foundation
import AVFoundation

/// A regra de corte (v4, aprovada no vídeo de 13 min):
/// - tira os sons marcados ([UH], [throatclearing]…, menos risada), palavras cortadas ("esp-")
///   e repetições ("um um", "do do do", "que vamos que vamos"), olhando de novo depois de cada tirada;
///   as bordas desses cortes caem onde o som acabou (até 50 ms de silêncio, ou no ponto mais baixo);
/// - pausa só é cortada onde o áudio está mesmo quieto (≥ 0,30 s abaixo do piso + 10 dB), deixando
///   0,13 s antes e 0,03 s depois. Buraco entre os tempos das palavras não conta: se tem som, fica.
enum CorteAutomatico {
    struct Trecho: Codable { var i: Double; var f: Double }
    struct Corte: Codable { var i: Double; var f: Double; var motivo: String }

    static func normalizar(_ p: String) -> String {
        let s = p.lowercased().precomposedStringWithCanonicalMapping
        return String(s.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    }

    /// Quais palavras saem e por quê ("som", "palavra cortada", "repetição").
    static func tiradasComMotivo(_ w: [PalavraTempo]) -> [Int: String] {
        let n = w.map { normalizar($0.p) }
        var fora: [Int: String] = [:]
        for (k, x) in w.enumerated() {
            let b = x.p.trimmingCharacters(in: .whitespacesAndNewlines)
            if b.hasPrefix("[") && !b.lowercased().contains("laugh") { fora[k] = "som" }
            else if b.hasSuffix("-") { fora[k] = "palavra cortada" }
        }
        var mudou = true
        while mudou {
            mudou = false
            let v = (0..<w.count).filter { fora[$0] == nil && !n[$0].isEmpty }
            guard v.count > 1 else { break }
            for j in 0..<(v.count - 1) {
                if n[v[j]] == n[v[j + 1]] { fora[v[j]] = "repetição"; mudou = true; break }
                if j + 3 < v.count && n[v[j]] == n[v[j + 2]] && n[v[j + 1]] == n[v[j + 3]] {
                    fora[v[j]] = "repetição"; fora[v[j + 1]] = "repetição"; mudou = true; break
                }
            }
        }
        return fora
    }

    static func tiradas(_ w: [PalavraTempo]) -> Set<Int> { Set(tiradasComMotivo(w).keys) }

    /// O que sai, em segundos, com o motivo. `audio`: 16 kHz mono.
    static func cortes(_ w0: [PalavraTempo], audio: [Float], minPausa: Double = 0.30,
                       antes: Double = 0.13, depois: Double = 0.03) -> [Corte] {
        let w = w0.filter { $0.i != nil && $0.f != nil }
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
        let dur = Double(audio.count) / 16000
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
            return Double(L > q(t) ? minimo(q(t), L) : q(t)) / 100
        }
        func iniReal(_ t: Double, _ limite: Double) -> Double {
            var i = q(t)
            let L = q(max(limite, t - 0.5))
            while i > L {
                if todosQuietos(i - 5, i) { return Double(i) / 100 - 0.03 }
                i -= 1
            }
            return Double(q(t) > L ? minimo(L, q(t)) : q(t)) / 100
        }

        var lista: [Corte] = []
        // 1) pausas: só onde o som está mesmo quieto
        var k = 0
        while k < nq {
            if quieto[k] {
                var j = k
                while j < nq && quieto[j] { j += 1 }
                let s = Double(k) / 100, e = Double(j) / 100
                if e - s >= minPausa || k == 0 || j == nq {
                    let a = k == 0 ? 0 : s + antes, b = j == nq ? dur : e - depois
                    if b - a > 0.02 { lista.append(Corte(i: a, f: b, motivo: "pausa")) }
                }
                k = j
            } else { k += 1 }
        }
        // 2) palavras tiradas (grupos seguidos)
        let fora = tiradasComMotivo(w)
        k = 0
        while k < w.count {
            guard let motivo = fora[k] else { k += 1; continue }
            var j = k
            while j + 1 < w.count && fora[j + 1] != nil { j += 1 }
            let ant = k > 0 ? w[k - 1].f! : 0
            let prox = j + 1 < w.count ? w[j + 1].i! : dur
            let a = max(iniReal(w[k].i!, ant), ant), b = min(fimReal(w[j].f!, prox), prox)
            let motivos = Set((k...j).compactMap { fora[$0] })
            let rotulo = motivos.count == 1 ? motivo : "repetição"
            let texto = w[k...j].map { $0.p }.joined(separator: " ")
            if b > a { lista.append(Corte(i: a, f: b, motivo: "\(rotulo): \(texto)")) }
            k = j + 1
        }
        lista.sort { $0.i < $1.i }
        var juntos: [Corte] = []
        for c in lista {
            if let u = juntos.last, c.i <= u.f + 0.02 {
                juntos[juntos.count - 1].f = max(u.f, c.f)
                if u.motivo == "pausa" { juntos[juntos.count - 1].motivo = c.motivo }
            } else { juntos.append(c) }
        }
        return juntos
    }

    /// Trechos que ficam (o complemento dos cortes).
    static func manter(_ cortes: [Corte], duracao: Double) -> [Trecho] {
        var fica: [Trecho] = []
        var antes = 0.0
        for c in cortes {
            if c.i > antes + 0.005 { fica.append(Trecho(i: antes, f: c.i)) }
            antes = max(antes, c.f)
        }
        if duracao > antes + 0.005 { fica.append(Trecho(i: antes, f: duracao)) }
        return fica
    }

    /// Trechos a manter, em segundos. `audio`: 16 kHz mono.
    static func trechos(_ w: [PalavraTempo], audio: [Float]) -> [Trecho] {
        manter(cortes(w, audio: audio), duracao: Double(audio.count) / 16000)
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
