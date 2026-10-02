import Foundation
import UIKit
import CoreImage

/// Desenha um bloco de legenda. A MESMA função serve à prévia do editor e ao vídeo final,
/// então o que aparece no editor é o que sai gravado (as medidas são frações do vídeo).
enum DesenhoLegenda {
    struct Saida {
        let imagem: CGImage
        let quadro: CGRect           // em pixels da tela, origem em cima à esquerda
    }

    static func fonte(_ e: EstiloLegenda, _ tamanho: CGFloat) -> UIFont {
        let pesos: [UIFont.Weight] = [.regular, .semibold, .bold, .heavy, .black]
        let peso = pesos[min(max(0, e.peso), pesos.count - 1)]
        if e.fonte.isEmpty { return .systemFont(ofSize: tamanho, weight: peso) }
        if e.fonte == "rounded" {
            let b = UIFont.systemFont(ofSize: tamanho, weight: peso)
            if let d = b.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: d, size: tamanho) }
            return b
        }
        var d = UIFontDescriptor(fontAttributes: [.family: e.fonte])
        if e.peso >= 2, let n = d.withSymbolicTraits(.traitBold) { d = n }
        return UIFont(descriptor: d, size: tamanho)
    }

    /// Reparte as palavras em `n` linhas deixando a linha mais larga o menor possível.
    static func equilibrar(_ larguras: [CGFloat], espaco: CGFloat, linhas n: Int) -> [[Int]] {
        let q = larguras.count
        let n = max(1, min(n, q))
        if n == 1 { return [Array(0..<q)] }
        func w(_ a: Int, _ b: Int) -> CGFloat {      // palavras a..<b
            larguras[a..<b].reduce(0, +) + CGFloat(max(0, b - a - 1)) * espaco
        }
        // melhor[k][i]: menor "linha mais larga" pondo as i primeiras palavras em k linhas
        var melhor = Array(repeating: Array(repeating: CGFloat.infinity, count: q + 1), count: n + 1)
        var corte = Array(repeating: Array(repeating: 0, count: q + 1), count: n + 1)
        melhor[0][0] = 0
        for k in 1...n {
            for i in k...q {
                for j in (k - 1)..<i where melhor[k - 1][j] < .infinity {
                    let v = max(melhor[k - 1][j], w(j, i))
                    if v < melhor[k][i] { melhor[k][i] = v; corte[k][i] = j }
                }
            }
        }
        var saida: [[Int]] = []
        var i = q
        for k in stride(from: n, through: 1, by: -1) {
            let j = corte[k][i]
            saida.insert(Array(j..<i), at: 0)
            i = j
        }
        return saida
    }

    static func desenhar(_ palavras: [PalavraLegenda], ativa: Int?, estilo e: EstiloLegenda,
                         linhasMax: Int, tela: CGSize) -> Saida? {
        guard !palavras.isEmpty, tela.width > 4, tela.height > 4 else { return nil }
        let textos = palavras.map { e.maiusculas ? $0.texto.uppercased() : $0.texto }
        let lado = min(tela.width, tela.height)
        var fs = max(6, CGFloat(e.tamanho) * lado)
        let maxW = max(40, CGFloat(e.larguraMax) * tela.width)

        func medir(_ fs: CGFloat) -> (UIFont, [CGFloat], CGFloat) {
            let f = fonte(e, fs)
            let kern = CGFloat(e.espacoLetras) * fs
            let ls = textos.map { t -> CGFloat in
                let w = (t as NSString).size(withAttributes: [.font: f, .kern: kern]).width
                return max(1, ceil(w - kern))            // o kern depois da última letra não conta
            }
            let esp = max(0, (" " as NSString).size(withAttributes: [.font: f]).width + CGFloat(e.espacoPalavras) * fs)
            return (f, ls, esp)
        }
        func largura(_ l: [Int], _ ls: [CGFloat], _ esp: CGFloat) -> CGFloat {
            l.reduce(0) { $0 + ls[$1] } + CGFloat(max(0, l.count - 1)) * esp
        }

        var (f, ls, esp) = medir(fs)
        var linhas: [[Int]] = []
        if palavras.dropLast().contains(where: { $0.quebraDepois }) {
            var atual: [Int] = []
            for i in palavras.indices {
                atual.append(i)
                if palavras[i].quebraDepois || i == palavras.count - 1 { linhas.append(atual); atual = [] }
            }
        } else {
            let teto = max(1, linhasMax)
            for n in 1...teto {
                linhas = equilibrar(ls, espaco: esp, linhas: n)
                if (linhas.map { largura($0, ls, esp) }.max() ?? 0) <= maxW { break }
            }
        }
        var maior = linhas.map { largura($0, ls, esp) }.max() ?? 1
        if maior > maxW {                                   // não coube: diminui a letra
            fs = max(6, fs * maxW / maior)
            (f, ls, esp) = medir(fs)
            maior = linhas.map { largura($0, ls, esp) }.max() ?? 1
        }

        let alt = ceil(f.lineHeight)
        let passo = alt * CGFloat(max(0.5, e.espacoLinhas))
        let altTotal = alt + CGFloat(linhas.count - 1) * passo
        let contorno = max(0, CGFloat(e.contorno)) * fs
        let padCaixaX = fs * 0.38, padCaixaY = fs * 0.14
        let margem = ceil(contorno + (e.sombra ? fs * 0.3 : 0) + (e.caixa ? padCaixaX : 0) + 2)
        let tamanho = CGSize(width: ceil(maior + margem * 2), height: ceil(altTotal + margem * 2))

        var origem = CGPoint(x: CGFloat(e.x) * tela.width - tamanho.width / 2,
                             y: CGFloat(e.y) * tela.height - tamanho.height / 2)
        origem.x = min(max(0, origem.x), max(0, tela.width - tamanho.width))
        origem.y = min(max(0, origem.y), max(0, tela.height - tamanho.height))
        origem.x.round(); origem.y.round()

        // onde cada palavra fica
        var pontos: [(Int, CGPoint)] = []
        var caixas: [CGRect] = []
        for (k, l) in linhas.enumerated() {
            let wl = largura(l, ls, esp)
            var x = margem + (maior - wl) / 2
            let y = margem + CGFloat(k) * passo
            caixas.append(CGRect(x: x - padCaixaX, y: y - padCaixaY, width: wl + padCaixaX * 2, height: alt + padCaixaY * 2))
            for i in l { pontos.append((i, CGPoint(x: x, y: y))); x += ls[i] + esp }
        }

        let kern = CGFloat(e.espacoLetras) * fs
        let cor = UIColor(hex: e.cor), corAtiva = UIColor(hex: e.corDestaque), corCont = UIColor(hex: e.corContorno)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = false; fmt.preferredRange = .standard
        let img = UIGraphicsImageRenderer(size: tamanho, format: fmt).image { r in
            let c = r.cgContext
            if e.caixa {
                // um caminho só para todas as linhas: onde as caixas se encostam não escurece em dobro
                let caminho = UIBezierPath()
                for q in caixas { caminho.append(UIBezierPath(roundedRect: q, cornerRadius: fs * 0.22)) }
                caminho.usesEvenOddFillRule = false
                UIColor(hex: e.corCaixa).withAlphaComponent(CGFloat(min(1, max(0, e.opacidadeCaixa)))).setFill()
                caminho.fill()
            }
            let sombra = { c.setShadow(offset: CGSize(width: 0, height: fs * 0.06), blur: fs * 0.16,
                                       color: UIColor.black.withAlphaComponent(0.85).cgColor) }
            if contorno > 0 {
                c.saveGState()
                c.setLineJoin(.round); c.setLineCap(.round)
                if e.sombra { sombra() }
                // largura positiva = só o traço; ele fica metade para fora, por isso 2×
                let attrs: [NSAttributedString.Key: Any] = [.font: f, .kern: kern, .strokeColor: corCont,
                                                            .strokeWidth: contorno * 2 / fs * 100]
                for (i, p) in pontos { (textos[i] as NSString).draw(at: p, withAttributes: attrs) }
                c.restoreGState()
            }
            c.saveGState()
            if e.sombra && contorno <= 0 { sombra() }
            for (i, p) in pontos {
                let attrs: [NSAttributedString.Key: Any] = [.font: f, .kern: kern,
                                                            .foregroundColor: (i == ativa && e.destaque) ? corAtiva : cor]
                (textos[i] as NSString).draw(at: p, withAttributes: attrs)
            }
            c.restoreGState()
        }
        guard let cg = img.cgImage else { return nil }
        return Saida(imagem: cg, quadro: CGRect(origin: origem, size: tamanho))
    }
}

/// Entrega a legenda do instante `t` já posicionada, para o Core Image pôr em cima do quadro.
/// Guarda as últimas imagens (um bloco é redesenhado só quando muda a palavra em destaque).
final class PintorLegenda: @unchecked Sendable {
    private let projeto: ProjetoLegenda
    private let blocos: [BlocoLegenda]
    private let tela: CGSize
    private let trava = NSLock()
    private var guardadas: [Int: CIImage] = [:]
    private var ordem: [Int] = []
    private var palpite = 0

    init(projeto: ProjetoLegenda, tela: CGSize) {
        self.projeto = projeto
        self.blocos = projeto.blocos
        self.tela = tela
    }

    /// Bloco no ar em `t` e a palavra que está sendo falada (índice dentro do bloco).
    static func ativo(_ blocos: [BlocoLegenda], _ palavras: [PalavraLegenda], em t: Double, palpite: Int = 0) -> (bloco: Int, palavra: Int)? {
        guard !blocos.isEmpty else { return nil }
        var k = min(max(0, palpite), blocos.count - 1)
        while k > 0 && blocos[k].inicio > t { k -= 1 }
        while k + 1 < blocos.count && blocos[k + 1].inicio <= t { k += 1 }
        let b = blocos[k]
        guard t >= b.inicio, t < b.fimExibicao else { return nil }
        var p = 0
        for (j, i) in b.indices.enumerated() where palavras[i].inicio <= t { p = j }
        return (k, p)
    }

    func imagem(em t: Double) -> CIImage? {
        trava.lock(); defer { trava.unlock() }
        guard let a = Self.ativo(blocos, projeto.palavras, em: t, palpite: palpite) else { return nil }
        palpite = a.bloco
        let destaque = projeto.estilo.destaque
        let chave = a.bloco * 4096 + (destaque ? a.palavra + 1 : 0)
        if let i = guardadas[chave] { return i }
        let b = blocos[a.bloco]
        guard let s = DesenhoLegenda.desenhar(Array(projeto.palavras[b.indices]), ativa: destaque ? a.palavra : nil,
                                              estilo: projeto.estilo, linhasMax: projeto.linhas, tela: tela) else { return nil }
        let img = CIImage(cgImage: s.imagem)
            .transformed(by: CGAffineTransform(translationX: s.quadro.minX, y: tela.height - s.quadro.maxY))
        guardadas[chave] = img; ordem.append(chave)
        if ordem.count > 6 { guardadas[ordem.removeFirst()] = nil }
        return img
    }
}
