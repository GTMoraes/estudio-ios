import Foundation

/// Trecho transcrito, independente do motor (local ou nuvem).
struct Segmento: Codable, Equatable {
    var inicio: Double
    var fim: Double
    var texto: String
    var palavras: [Palavra]

    struct Palavra: Codable, Equatable {
        var inicio: Double
        var fim: Double
        var texto: String      // com o espaço inicial, como o Whisper devolve
    }
}

/// Mesmas regras de legenda do whisper.frx9.com (webapp/app.py: _to_srt):
/// blocos de até 90 caracteres e 7 s, quebra em pausa > 0,8 s e em fim de
/// frase quando o bloco já tem 40% do tamanho.
enum Legenda {
    static let maxCaracteres = 90
    static let maxDuracao = 7.0
    static let maxPausa = 0.8
    static let fimDeFrase: [Character] = [".", "!", "?", "…", ":", ";"]
    static let loopMinimo = 12

    typealias Bloco = (inicio: Double, fim: Double, texto: String)

    static func srt(_ segmentos: [Segmento]) -> String {
        let palavras = segmentos.flatMap { $0.palavras }.filter { !$0.texto.trimmingCharacters(in: .whitespaces).isEmpty }
        let blocos = palavras.isEmpty ? blocosDeSegmentos(segmentos) : blocosDePalavras(palavras)
        return blocos.enumerated().map { i, b in
            "\(i + 1)\n\(tempo(b.inicio)) --> \(tempo(b.fim))\n\(b.texto)\n"
        }.joined(separator: "\n")
    }

    /// Texto corrido: um trecho por linha (como o site faz no modo de trilhas).
    static func texto(_ segmentos: [Segmento]) -> String {
        segmentos.map { $0.texto.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func tempo(_ t: Double) -> String {
        let t = max(0, t)
        var ms = Int((t.truncatingRemainder(dividingBy: 1) * 1000).rounded())
        var s = Int(t)
        if ms >= 1000 { ms -= 1000; s += 1 }
        return String(format: "%02d:%02d:%02d,%03d", s / 3600, s % 3600 / 60, s % 60, ms)
    }

    static func hms(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    private static func juntar(_ g: [Segmento.Palavra]) -> String {
        g.map(\.texto).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func blocosDePalavras(_ palavras: [Segmento.Palavra]) -> [Bloco] {
        var grupos: [[Segmento.Palavra]] = []
        var atual: [Segmento.Palavra] = []
        for p in palavras {
            if let ultima = atual.last, let primeira = atual.first {
                let texto = juntar(atual)
                let pausa = p.inicio - ultima.fim
                if texto.count + p.texto.count > maxCaracteres
                    || p.fim - primeira.inicio > maxDuracao
                    || pausa > maxPausa {
                    grupos.append(atual)
                    atual = []
                }
            }
            atual.append(p)
            let texto = juntar(atual)
            if let c = texto.last, fimDeFrase.contains(c), Double(texto.count) >= Double(maxCaracteres) * 0.4 {
                grupos.append(atual)
                atual = []
            }
        }
        if !atual.isEmpty { grupos.append(atual) }
        return grupos.map { ($0.first!.inicio, $0.last!.fim, juntar($0)) }
    }

    /// Sem palavras: quebra segmentos longos em frases, com tempo proporcional.
    static func blocosDeSegmentos(_ segmentos: [Segmento]) -> [Bloco] {
        var saida: [Bloco] = []
        for seg in segmentos {
            let texto = seg.texto.trimmingCharacters(in: .whitespacesAndNewlines)
            if texto.isEmpty { continue }
            let ini = seg.inicio, fim = max(seg.fim, seg.inicio)
            if texto.count <= maxCaracteres && fim - ini <= maxDuracao {
                saida.append((ini, fim, texto)); continue
            }
            var partes: [String] = []
            var buf = ""
            let pontuacao = ".!?…:;,"
            for c in texto {
                // pontuação seguida ("...", "?!") fica no mesmo pedaço
                if !buf.isEmpty || partes.isEmpty || !pontuacao.contains(c) {
                    buf.append(c)
                } else {
                    partes[partes.count - 1].append(c)
                    continue
                }
                if pontuacao.contains(c) { partes.append(buf); buf = "" }
            }
            if !buf.isEmpty { partes.append(buf) }
            var pedacos: [String] = []
            var junta = ""
            for p in partes.map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
                if !junta.isEmpty && junta.count + 1 + p.count > maxCaracteres {
                    pedacos.append(junta); junta = p
                } else {
                    junta = junta.isEmpty ? p : junta + " " + p
                }
            }
            if !junta.isEmpty { pedacos.append(junta) }
            let total = Double(max(1, pedacos.reduce(0) { $0 + $1.count }))
            var t = ini
            for p in pedacos {
                let d = (fim - ini) * Double(p.count) / total
                saida.append((t, t + d, p)); t += d
            }
        }
        return saida
    }

    /// Maior sequência de trechos idênticos seguidos (assinatura de loop de
    /// alucinação do Whisper) e o segundo em que começa.
    static func loop(_ segmentos: [Segmento]) -> (vezes: Int, inicio: Double) {
        var maior = 0, maiorIni = 0.0, seq = 0, seqIni = 0.0
        var anterior: String?
        for s in segmentos {
            let t = s.texto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t.isEmpty { seq = 0; anterior = nil; continue }
            if t == anterior { seq += 1 } else { seq = 1; seqIni = s.inicio; anterior = t }
            if seq > maior { maior = seq; maiorIni = seqIni }
        }
        return (maior, maiorIni)
    }

    /// Texto e legenda finais, com a mesma rede de segurança do site.
    static func resultado(_ segmentos: [Segmento]) -> (texto: String, srt: String?) {
        let corpo = texto(segmentos)
        let l = loop(segmentos)
        if l.vezes >= loopMinimo {
            let aviso = "⚠️ ATENÇÃO: possível loop de alucinação do Whisper (\(l.vezes)x a mesma frase a partir de \(hms(l.inicio))). O áudio desse trecho não foi transcrito — reprocesse este arquivo.\n\n"
            return (aviso + corpo, nil)
        }
        return (corpo, segmentos.isEmpty ? nil : srt(segmentos))
    }
}
