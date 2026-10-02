import Foundation
import SwiftUI
import UIKit
import Photos

// MARK: - modelo

/// Uma palavra da legenda, com o tempo dela. Os blocos são só marcas nas palavras
/// (`fimDeBloco`), então dividir, juntar e reagrupar nunca perdem o texto nem os tempos.
struct PalavraLegenda: Codable, Equatable {
    var texto: String
    var inicio: Double
    var fim: Double
    var fimDeBloco = false
    var quebraDepois = false         // quebra de linha manual depois desta palavra
    var abreTrecho: Bool?            // primeira palavra de um trecho do transcritor (começo de frase falada)
}

struct EstiloLegenda: Codable, Equatable {
    var fonte = ""                   // "" = San Francisco; "rounded" = arredondada; senão, família
    var peso = 4                     // 0 normal … 4 black
    var tamanho = 0.058              // fração do lado menor do vídeo
    var cor = "#FFFFFF"
    var contorno = 0.10              // fração do tamanho da fonte
    var corContorno = "#000000"
    var sombra = false
    var caixa = false
    var corCaixa = "#000000"
    var opacidadeCaixa = 0.72
    var maiusculas = false
    var destaque = false
    var corDestaque = "#FFD60A"
    var espacoLinhas = 1.0           // multiplicador da altura da linha
    var espacoLetras = 0.0           // fração do tamanho da fonte
    var espacoPalavras = 0.0         // fração do tamanho da fonte (além do espaço normal)
    var x = 0.5                      // centro da legenda, 0…1
    var y = 0.76
    var larguraMax = 0.86            // fração da largura do vídeo

    static let pesos = ["Normal", "Semi", "Negrito", "Pesado", "Black"]
    static let fontes: [(nome: String, valor: String)] = [
        ("San Francisco", ""), ("SF arredondada", "rounded"), ("Avenir Next", "Avenir Next"),
        ("Avenir Next Condensed", "Avenir Next Condensed"), ("Helvetica Neue", "Helvetica Neue"),
        ("Futura", "Futura"), ("Gill Sans", "Gill Sans"), ("Arial Rounded", "Arial Rounded MT Bold"),
        ("Verdana", "Verdana"), ("Georgia", "Georgia"), ("Didot", "Didot"), ("Rockwell", "Rockwell"),
        ("American Typewriter", "American Typewriter"), ("Marker Felt", "Marker Felt"),
        ("Chalkboard", "Chalkboard SE"), ("Noteworthy", "Noteworthy"), ("Menlo", "Menlo"),
    ]
}

/// Estilo pronto: aparência + como os blocos são montados.
struct PresetLegenda: Identifiable {
    let id: String
    let nome: String
    let estilo: EstiloLegenda
    let palavrasPorBloco: Int
    let linhas: Int

    static let todos: [PresetLegenda] = {
        var classica = EstiloLegenda()
        classica.peso = 3

        var viral = EstiloLegenda()
        viral.tamanho = 0.095; viral.maiusculas = true; viral.contorno = 0.11; viral.sombra = true
        viral.destaque = true; viral.y = 0.64

        var caixa = EstiloLegenda()
        caixa.peso = 2; caixa.tamanho = 0.052; caixa.contorno = 0; caixa.caixa = true; caixa.espacoLinhas = 1.38

        var amarela = EstiloLegenda()
        amarela.fonte = "Avenir Next Condensed"; amarela.tamanho = 0.075; amarela.cor = "#FFE14D"; amarela.y = 0.72

        return [
            PresetLegenda(id: "classica", nome: "Clássica", estilo: classica, palavrasPorBloco: 0, linhas: 2),
            PresetLegenda(id: "viral", nome: "Viral", estilo: viral, palavrasPorBloco: 2, linhas: 1),
            PresetLegenda(id: "caixa", nome: "Caixa", estilo: caixa, palavrasPorBloco: 4, linhas: 2),
            PresetLegenda(id: "amarela", nome: "Amarela", estilo: amarela, palavrasPorBloco: 3, linhas: 1),
        ]
    }()
}

struct BlocoLegenda: Identifiable, Equatable {
    let indices: Range<Int>          // palavras do bloco
    let inicio: Double
    let fim: Double                  // fim da última palavra
    let fimExibicao: Double          // até quando fica na tela
    var id: Int { indices.lowerBound }
}

struct ProjetoLegenda: Codable, Equatable {
    var palavras: [PalavraLegenda] = []
    var estilo = EstiloLegenda()
    var palavrasPorBloco = 0         // 0 = por frase
    var linhas = 2

    // MARK: blocos

    var blocos: [BlocoLegenda] {
        var faixas: [Range<Int>] = []
        var a = 0
        for i in palavras.indices where palavras[i].fimDeBloco || i == palavras.count - 1 {
            faixas.append(a..<(i + 1)); a = i + 1
        }
        return faixas.enumerated().map { k, f in
            let ini = palavras[f.lowerBound].inicio
            let fim = max(ini + 0.05, palavras[f.upperBound - 1].fim)
            let proximo = k + 1 < faixas.count ? palavras[faixas[k + 1].lowerBound].inicio : .infinity
            return BlocoLegenda(indices: f, inicio: ini, fim: fim, fimExibicao: max(fim, min(fim + 0.25, proximo)))
        }
    }

    func texto(_ b: BlocoLegenda) -> String {
        var s = ""
        for i in b.indices {
            s += palavras[i].texto
            if i < b.indices.upperBound - 1 { s += palavras[i].quebraDepois ? "\n" : " " }
        }
        return s
    }

    private static let fimDeFrase: Set<Character> = [".", "!", "?", "…"]

    /// A palavra `i` começa uma frase falada? O transcritor marca o começo de cada trecho; em vídeo
    /// editado (pausas cortadas) é a única pista, porque não sobra pausa nem pontuação. Projeto antigo,
    /// sem a marca: vale a maiúscula que o transcritor põe no começo do trecho.
    private func abreFrase(_ i: Int, temMarcas: Bool) -> Bool {
        if temMarcas { return palavras[i].abreTrecho == true }
        guard let l = palavras[i].texto.first(where: { $0.isLetter }) else { return false }
        return l.isUppercase
    }

    private func fechaFrase(_ i: Int, temMarcas: Bool) -> Bool {
        if let u = palavras[i].texto.last, Self.fimDeFrase.contains(u) { return true }
        guard i + 1 < palavras.count else { return true }
        if palavras[i + 1].inicio - palavras[i].fim > 0.7 { return true }
        return abreFrase(i + 1, temMarcas: temMarcas)
    }

    /// Remonta os blocos (por frase ou por número de palavras). Apaga divisões e quebras manuais.
    /// Um bloco nunca mistura o fim de uma frase com o começo da outra. Frase que não cabe num bloco
    /// é repartida em pedaços de tamanho parecido (de preferência depois de uma vírgula), em vez de
    /// encher um bloco e deixar uma sobra.
    mutating func reagrupar() {
        guard !palavras.isEmpty else { return }
        let temMarcas = palavras.contains { $0.abreTrecho != nil }
        let limite = 36 * max(1, linhas)
        var a = 0
        while a < palavras.count {
            var b = a                                            // frase = a...b
            while !fechaFrase(b, temMarcas: temMarcas) { b += 1 }
            for i in a...b { palavras[i].quebraDepois = false; palavras[i].fimDeBloco = false }
            if palavrasPorBloco > 0 {
                var conta = 0
                for i in a...b {
                    conta += 1
                    if conta >= palavrasPorBloco { palavras[i].fimDeBloco = true; conta = 0 }
                }
            } else {
                let total = (a...b).reduce(0) { $0 + palavras[$1].texto.count + 1 } - 1
                let pedacos = max(1, Int((Double(total) / Double(limite)).rounded(.up)))
                if pedacos > 1 {
                    let alvo = Double(total) / Double(pedacos)
                    var letras = 0.0, feitos = 0
                    for i in a..<b where feitos < pedacos - 1 {
                        letras += Double(palavras[i].texto.count + 1)
                        let proxima = Double(palavras[i + 1].texto.count + 1)
                        let virgula = palavras[i].texto.hasSuffix(",") && letras >= alvo * 0.6
                        if virgula || letras + proxima / 2 > alvo {
                            palavras[i].fimDeBloco = true; letras = 0; feitos += 1
                        }
                    }
                }
            }
            palavras[b].fimDeBloco = true
            a = b + 1
        }
    }

    // MARK: edição

    mutating func dividir(depoisDe i: Int) {
        guard palavras.indices.contains(i) else { return }
        palavras[i].fimDeBloco = true
        palavras[i].quebraDepois = false
    }

    /// Junta o bloco com o seguinte.
    mutating func juntar(_ b: BlocoLegenda) {
        let u = b.indices.upperBound - 1
        guard u < palavras.count - 1 else { return }
        palavras[u].fimDeBloco = false
    }

    mutating func apagar(_ b: BlocoLegenda) {
        palavras.removeSubrange(b.indices)
        if let u = palavras.indices.last { palavras[u].fimDeBloco = true }
    }

    /// Texto novo do bloco. Mesmo número de palavras: os tempos ficam. Senão, o tempo do bloco
    /// é repartido entre as palavras novas pelo tamanho de cada uma.
    mutating func trocarTexto(_ b: BlocoLegenda, por texto: String) {
        var novas: [(String, Bool)] = []
        let linhasTexto = texto.split(separator: "\n", omittingEmptySubsequences: true)
        for (k, l) in linhasTexto.enumerated() {
            let ps = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (j, p) in ps.enumerated() {
                novas.append((p, j == ps.count - 1 && k < linhasTexto.count - 1))
            }
        }
        guard !novas.isEmpty else { apagar(b); return }
        if novas.count == b.indices.count {
            for (k, i) in b.indices.enumerated() {
                palavras[i].texto = novas[k].0
                palavras[i].quebraDepois = novas[k].1
            }
            return
        }
        let ini = b.inicio, fim = b.fim
        let pesos = novas.map { Double($0.0.count + 1) }
        let total = pesos.reduce(0, +)
        var t = ini
        var lista: [PalavraLegenda] = []
        for (k, n) in novas.enumerated() {
            let d = (fim - ini) * pesos[k] / total
            lista.append(PalavraLegenda(texto: n.0, inicio: t, fim: t + d, fimDeBloco: k == novas.count - 1, quebraDepois: n.1))
            t += d
        }
        palavras.replaceSubrange(b.indices, with: lista)
    }

    /// Move o começo (ou o fim) do bloco, sem passar por cima dos vizinhos.
    mutating func moverInicio(_ b: BlocoLegenda, para t: Double) {
        let i = b.indices.lowerBound
        let piso = i > 0 ? palavras[i - 1].fim : 0
        palavras[i].inicio = min(max(piso, t), palavras[i].fim - 0.03)
    }

    mutating func moverFim(_ b: BlocoLegenda, para t: Double) {
        let i = b.indices.upperBound - 1
        let teto = i + 1 < palavras.count ? palavras[i + 1].inicio : .infinity
        palavras[i].fim = max(min(teto, t), palavras[i].inicio + 0.03)
    }

    mutating func aplicar(_ p: PresetLegenda) {
        // a posição e a largura que você já ajustou não mudam com o estilo pronto
        var e = p.estilo
        if estilo != EstiloLegenda() { e.x = estilo.x; e.larguraMax = estilo.larguraMax }
        estilo = e
        palavrasPorBloco = p.palavrasPorBloco
        linhas = p.linhas
        reagrupar()
    }

    // MARK: entrada e saída

    /// Da transcrição (com o tempo de cada palavra) para o projeto.
    static func criar(_ segmentos: [Segmento]) -> ProjetoLegenda {
        var p = ProjetoLegenda()
        for s in segmentos {
            let comTempo = s.palavras.filter { !$0.texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if comTempo.isEmpty {
                // sem tempo por palavra: reparte o trecho pelo tamanho das palavras
                let ps = s.texto.split(separator: " ").map(String.init)
                let total = Double(ps.reduce(0) { $0 + $1.count + 1 })
                var t = s.inicio
                for w in ps where total > 0 {
                    let d = (s.fim - s.inicio) * Double(w.count + 1) / total
                    p.palavras.append(PalavraLegenda(texto: w, inicio: t, fim: t + d)); t += d
                }
            } else {
                let primeira = p.palavras.count
                defer { if primeira < p.palavras.count { p.palavras[primeira].abreTrecho = true } }
                for w in comTempo {
                    let txt = w.texto.trimmingCharacters(in: .whitespacesAndNewlines)
                    // o Whisper às vezes separa a pontuação: cola na palavra anterior
                    if txt.allSatisfy({ $0.isPunctuation }), let u = p.palavras.indices.last {
                        p.palavras[u].texto += txt
                        continue
                    }
                    p.palavras.append(PalavraLegenda(texto: txt, inicio: w.inicio, fim: max(w.fim, w.inicio + 0.02)))
                }
            }
        }
        for i in p.palavras.indices where p.palavras[i].abreTrecho == nil { p.palavras[i].abreTrecho = false }
        p.reagrupar()
        return p
    }

    var srt: String {
        blocos.enumerated().map { k, b in
            "\(k + 1)\n\(Legenda.tempo(b.inicio)) --> \(Legenda.tempo(b.fimExibicao))\n\(texto(b))\n"
        }.joined(separator: "\n")
    }

    var textoCorrido: String { blocos.map { texto($0).replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n") }
}

// MARK: - originais guardados (para "Editar novamente" e para o editor de legenda)

enum Originais {
    static let nomeProjeto = "legenda.json"

    static var raiz: URL {
        var u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Originais", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }

    static func pasta(_ id: UUID) -> URL { raiz.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func arquivo(_ id: UUID, _ nome: String) -> URL { pasta(id).appendingPathComponent(nome) }
    static func apagar(_ id: UUID) { try? FileManager.default.removeItem(at: pasta(id)) }

    /// Por quantos dias a cópia de um vídeo recebido pelo Compartilhar fica guardada (-1 = indefinido).
    static var dias: Int {
        let v = UserDefaults.standard.object(forKey: "originaisDias") == nil ? 7 : UserDefaults.standard.integer(forKey: "originaisDias")
        return v == 0 ? 7 : v
    }

    static func tamanhoEmDisco() -> Int64 {
        guard let e = FileManager.default.enumerator(at: raiz, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    static func lerProjeto(_ id: UUID) -> ProjetoLegenda? {
        guard let d = try? Data(contentsOf: arquivo(id, nomeProjeto)) else { return nil }
        return try? JSONDecoder().decode(ProjetoLegenda.self, from: d)
    }

    static func gravarProjeto(_ id: UUID, _ p: ProjetoLegenda) {
        try? FileManager.default.createDirectory(at: pasta(id), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: arquivo(id, nomeProjeto), options: .atomic) }
    }
}

// MARK: - de onde veio um arquivo

/// Referência ao original, para buscá-lo de novo sem guardar cópia: o vídeo da galeria (pelo
/// identificador), um arquivo do app Arquivos (por um marcador) ou um arquivo de Resultados.
/// Quem veio pelo Compartilhar não tem referência: o iPhone entrega só uma cópia.
struct Procedencia: Codable, Equatable {
    enum Tipo: String, Codable { case fotos, arquivo, resultado }
    var tipo: Tipo
    var fotos: String?               // identificador na galeria
    var marcador: Data?              // marcador do app Arquivos
    var item: UUID?                  // item de Resultados
    var nome: String?

    func trazer(para destino: URL, arquivoDoResultado: URL?) async throws {
        try? FileManager.default.removeItem(at: destino)
        switch tipo {
        case .resultado:
            guard let u = arquivoDoResultado, FileManager.default.fileExists(atPath: u.path) else {
                throw ErroApp("O arquivo original estava num item de Resultados que foi apagado.")
            }
            try FileManager.default.copyItem(at: u, to: destino)
        case .arquivo:
            guard let marcador else { throw ErroApp("O original não foi encontrado no app Arquivos.") }
            var velho = false
            guard let u = try? URL(resolvingBookmarkData: marcador, bookmarkDataIsStale: &velho) else {
                throw ErroApp("O arquivo original (\(nome ?? "sem nome")) foi movido ou apagado do app Arquivos.")
            }
            let acesso = u.startAccessingSecurityScopedResource()
            defer { if acesso { u.stopAccessingSecurityScopedResource() } }
            // o coordenador baixa o arquivo se ele estiver só no iCloud
            var erroCoord: NSError?
            var erroCopia: Error?
            NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &erroCoord) { lido in
                do { try FileManager.default.copyItem(at: lido, to: destino) } catch { erroCopia = error }
            }
            if erroCoord != nil || erroCopia != nil {
                throw ErroApp("O arquivo original (\(nome ?? u.lastPathComponent)) foi movido ou apagado do app Arquivos.")
            }
        case .fotos:
            let estado = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard estado == .authorized || estado == .limited else {
                throw ErroApp("Para buscar o vídeo original na galeria, libere o acesso em Ajustes do iPhone › Privacidade › Fotos › Estúdio.")
            }
            guard let fotos, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [fotos], options: nil).firstObject else {
                throw ErroApp(estado == .limited
                    ? "O vídeo original não está entre as fotos liberadas para o Estúdio (ou foi apagado da galeria)."
                    : "O vídeo original foi apagado da galeria.")
            }
            let recursos = PHAssetResource.assetResources(for: asset)
            // a versão atual do vídeo (editada, se foi editado), como a galeria entregou da primeira vez
            let ordem: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
            guard let recurso = ordem.compactMap({ t in recursos.first { $0.type == t } }).first ?? recursos.first else {
                throw ErroApp("A galeria não entregou o vídeo original.")
            }
            let opcoes = PHAssetResourceRequestOptions()
            opcoes.isNetworkAccessAllowed = true                 // baixa do iCloud se precisar
            do { try await PHAssetResourceManager.default().writeData(for: recurso, toFile: destino, options: opcoes) }
            catch { throw ErroApp("Não consegui trazer o vídeo da galeria: \(error.localizedDescription)") }
        }
    }
}

// MARK: - cores em texto ("#RRGGBB")

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}
