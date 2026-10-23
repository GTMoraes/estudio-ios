import Foundation
import CryptoKit
import Observation

// MARK: - modelo

/// O CrisperWhisper do corte automático. Fica em "No meu iPhone › Estúdio › CrisperWhisper" (a pasta
/// sobrevive às atualizações do app). Se faltar algo, é baixado de cdn.frx9.com/modelos/crisperwhisper/,
/// pela lista `manifesto.json` (arquivos grandes em partes de 19 MB, cada arquivo conferido pelo SHA-256).
enum ModeloCrisper {
    static let base = URL(string: "https://cdn.frx9.com/modelos/crisperwhisper/")!
    static let tamanhoAproximado: Int64 = 1_230_000_000

    static var pasta: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrisperWhisper", isDirectory: true)
    }

    /// Marca de download pela metade: enquanto existir, o modelo não conta como pronto.
    static var marcaIncompleto: URL { pasta.appendingPathComponent(".incompleto") }

    static var pronto: Bool {
        !FileManager.default.fileExists(atPath: marcaIncompleto.path)
            && CrisperModelo.acharPasta(em: pasta) != nil
            && CrisperModelo.acharArquivo("tokenizer.json", em: pasta) != nil
            && CrisperModelo.acharArquivo("generation_config.json", em: pasta) != nil
    }

    static func tamanhoEmDisco() -> Int64 { Self.tamanho(pasta) }

    static func tamanho(_ u: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var t: Int64 = 0
        for case let x as URL in e { t += Int64((try? x.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return t
    }

    static func apagar() { try? FileManager.default.removeItem(at: pasta) }

    struct Manifesto: Codable {
        struct Arquivo: Codable {
            var caminho: String           // relativo à pasta (ex.: "TextDecoder.mlmodelc/weights/weight.bin")
            var bytes: Int64
            var sha256: String
            var partes: Int               // 0 = arquivo inteiro; N = caminho.part00 … partN-1
        }
        var versao: Int
        var parte: Int64                  // tamanho de cada parte
        var arquivos: [Arquivo]
        var total: Int64 { arquivos.reduce(0) { $0 + $1.bytes } }
    }

    /// Baixa o que falta. Arquivo já completo (tamanho certo) é mantido; arquivo pela metade continua
    /// da última parte inteira. progresso(0…1, mensagem).
    /// Serve para o CrisperWhisper e para o alinhador: `origem` no cdn, `pasta` no iPhone.
    /// `pular`: prefixo de caminho que não precisa vir (ex.: o T3.mlpackage do Chatterbox depois de compilado).
    static func baixar(de origem: URL = ModeloCrisper.base, para pasta: URL = ModeloCrisper.pasta, nome: String = "o modelo",
                       pular: String? = nil,
                       progresso: @escaping @Sendable (Double, String) -> Void) async throws {
        let base = origem
        let marcaIncompleto = pasta.appendingPathComponent(".incompleto")
        let (dados, resp) = try await URLSession.shared.data(from: base.appendingPathComponent("manifesto.json"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ErroApp("Não achei a lista do modelo no servidor (manifesto.json).")
        }
        var m = try JSONDecoder().decode(Manifesto.self, from: dados)
        if let pular { m.arquivos.removeAll { $0.caminho.hasPrefix(pular) } }
        let fm = FileManager.default
        try fm.createDirectory(at: pasta, withIntermediateDirectories: true)
        fm.createFile(atPath: marcaIncompleto.path, contents: Data())
        var feitos: Int64 = 0
        let total = max(m.total, 1)
        for a in m.arquivos {
            try Task.checkCancellation()
            let destino = pasta.appendingPathComponent(a.caminho)
            if let t = (try? fm.attributesOfItem(atPath: destino.path))?[.size] as? Int64, t == a.bytes {
                feitos += a.bytes; continue
            }
            try fm.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = destino.appendingPathExtension("baixando")
            var ja = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int64) ?? 0
            if a.partes == 0 || ja > a.bytes { ja = 0 }
            if a.partes > 0 { ja = ja / m.parte * m.parte }
            if ja == 0 { try? fm.removeItem(at: tmp); fm.createFile(atPath: tmp.path, contents: nil) }
            let fh = try FileHandle(forWritingTo: tmp)
            do {
                try fh.truncate(atOffset: UInt64(ja))
                try fh.seekToEnd()
                let nomes: [String] = a.partes == 0 ? [a.caminho]
                    : (Int(ja / m.parte)..<a.partes).map { String(format: "%@.part%02d", a.caminho, $0) }
                for n in nomes {
                    try Task.checkCancellation()
                    let (arq, r) = try await URLSession.shared.download(from: base.appendingPathComponent(n))
                    guard (r as? HTTPURLResponse)?.statusCode == 200 else {
                        try? fm.removeItem(at: arq)
                        throw ErroApp("Não consegui baixar \(n) (HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0)).")
                    }
                    let d = try Data(contentsOf: arq, options: .alwaysMapped)
                    try fh.write(contentsOf: d)
                    try? fm.removeItem(at: arq)
                    let agora = Int64(try fh.offset())
                    progresso(Double(feitos + agora) / Double(total), "Baixando \(nome)")
                }
                try fh.close()
            } catch {
                try? fh.close()
                throw error
            }
            let tam = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int64) ?? 0
            guard tam == a.bytes else {
                try? fm.removeItem(at: tmp)
                throw ErroApp("\(a.caminho) veio com tamanho errado. Tente de novo.")
            }
            progresso(Double(feitos + a.bytes) / Double(total), "Conferindo \((a.caminho as NSString).lastPathComponent)")
            guard try sha256(tmp) == a.sha256.lowercased() else {
                try? fm.removeItem(at: tmp)
                throw ErroApp("\(a.caminho) veio corrompido (o SHA-256 não bate). Tente de novo.")
            }
            try? fm.removeItem(at: destino)
            try fm.moveItem(at: tmp, to: destino)
            feitos += a.bytes
        }
        try? fm.removeItem(at: marcaIncompleto)
        progresso(1, "Pronto")
    }

    static func sha256(_ u: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: u)
        defer { try? fh.close() }
        var h = SHA256()
        while true {
            let ok: Bool = try autoreleasepool {
                guard let d = try fh.read(upToCount: 8 << 20), !d.isEmpty else { return false }
                h.update(data: d)
                return true
            }
            if !ok { break }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Download do modelo em andamento (sobrevive a sair e voltar dos Ajustes).
@MainActor @Observable
final class BaixaCrisper {
    static let shared = BaixaCrisper()
    var progresso: Double?
    var mensagem: String?
    private var tarefa: Task<Void, Never>?

    var baixando: Bool { tarefa != nil }

    func iniciar() {
        guard tarefa == nil else { return }
        progresso = 0; mensagem = "Baixando"
        tarefa = Task {
            do {
                let aviso: @Sendable (Double, String) -> Void = { p, msg in
                    Task { @MainActor in
                        guard BaixaCrisper.shared.tarefa != nil else { return }
                        BaixaCrisper.shared.progresso = p; BaixaCrisper.shared.mensagem = msg
                    }
                }
                if !ModeloCrisper.pronto {
                    try await ModeloCrisper.baixar(nome: "o CrisperWhisper", progresso: aviso)
                }
                if !ModeloAlinhador.pronto {
                    try await ModeloCrisper.baixar(de: ModeloAlinhador.base, para: ModeloAlinhador.pasta,
                                                   nome: "o alinhador", progresso: aviso)
                }
                mensagem = "Modelos prontos."
            } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                mensagem = "Download pausado. Toque em Baixar para continuar de onde parou."
            } catch {
                mensagem = "Falhou: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
            progresso = nil
            tarefa = nil
        }
    }

    func cancelar() { tarefa?.cancel() }
}

// MARK: - transcrições guardadas

/// Transcrição verbatim de cada arquivo, guardada para rodar o corte de novo sem transcrever.
/// A chave é o conteúdo do arquivo (tamanho + começo + fim), então vale para cópias do mesmo vídeo.
/// Uma transcrição de outra versão do transcritor é ignorada (e refeita).
enum TranscricoesGuardadas {
    struct Guardada: Codable {
        var versao: Int
        var texto: String
        var palavras: [PalavraTempo]
        var duracao: Double
        var criada: Date
        var alinhadas: [PalavraTempo]? = nil      // tempos do alinhador (nil = ainda não alinhado)
        var versaoAlinhador: Int? = nil
    }

    static var pasta: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CorteAutomatico/transcricoes", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func chave(_ url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let tam = try fh.seekToEnd()
        var h = SHA256()
        h.update(data: Data(String(tam).utf8))
        try fh.seek(toOffset: 0)
        if let d = try fh.read(upToCount: 1 << 20) { h.update(data: d) }
        if tam > 2 << 20 {
            try fh.seek(toOffset: tam - (1 << 20))
            if let d = try fh.read(upToCount: 1 << 20) { h.update(data: d) }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func ler(_ url: URL) -> Guardada? {
        guard let k = try? chave(url),
              let d = try? Data(contentsOf: pasta.appendingPathComponent(k + ".json")),
              let g = try? JSONDecoder().decode(Guardada.self, from: d),
              g.versao == CrisperTranscritor.versao else { return nil }
        return g
    }

    static func gravar(_ g: Guardada, para url: URL) {
        guard let k = try? chave(url), let d = try? JSONEncoder().encode(g) else { return }
        try? d.write(to: pasta.appendingPathComponent(k + ".json"), options: .atomic)
    }

    static func quantidade() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: pasta.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }
    static func tamanhoEmDisco() -> Int64 { ModeloCrisper.tamanho(pasta) }
    static func apagarTudo() { try? FileManager.default.removeItem(at: pasta) }
}

// MARK: - proposta de corte

/// O que a regra v4 faria num arquivo: o que fica e o que sai (tempos no arquivo), com o motivo.
struct PropostaCorte: Codable {
    struct Faixa: Codable {
        var i: Double
        var f: Double
        var texto: String             // motivo: "pausa", "som: [UH]", "palavra cortada: esp-", "repetição: do do"
    }
    var duracao: Double
    var texto: String
    var manter: [CorteAutomatico.Trecho]
    var tirar: [Faixa]
    var reparos = 0, recomecos = 0, fimRecuperado = 0
    var transcricaoGuardada = false
    var alinhado = false                // tempos do alinhador (senão, os do CrisperWhisper)
    var pastaDiagnostico: String?
}

/// Transcreve (ou pega a transcrição guardada) e aplica a regra de corte. O modelo fica carregado
/// entre um arquivo e outro e é solto com `liberar()` (usa ~650 MB).
final class ServicoCorte: @unchecked Sendable {
    static let shared = ServicoCorte()
    private var transcritor: CrisperTranscritor?
    private let trava = NSLock()

    func liberar() { trava.withLock { transcritor = nil } }

    private func carregado() async throws -> CrisperTranscritor {
        if let t = trava.withLock({ transcritor }) { return t }
        guard ModeloCrisper.pronto else {
            throw ErroApp("O modelo do corte automático não está no iPhone. Baixe em Ajustes › Deixar o app pronto.")
        }
        let pasta = ModeloCrisper.pasta
        let carga = Task.detached(priority: .userInitiated) { try CrisperTranscritor(pasta: pasta, onde: .gpu) }
        let novo = try await withTaskCancellationHandler { try await carga.value } onCancel: { carga.cancel() }
        trava.withLock { transcritor = novo }
        return novo
    }

    /// progresso(mensagem, 0…1 ou nil).
    func propor(_ url: URL, progresso: @escaping @Sendable (String, Double?) -> Void) async throws -> PropostaCorte {
        progresso("Lendo o áudio", nil)
        let audio = try await CrisperTranscritor.lerAudio(url)
        try Task.checkCancellation()
        var guardada = TranscricoesGuardadas.ler(url)
        var r: CrisperTranscritor.Resultado?
        if guardada == nil {
            progresso("Carregando o modelo (cerca de 30 s)", nil)
            let t = try await carregado()
            let trabalho = Task.detached(priority: .userInitiated) {
                try t.transcrever(audio) { p, msg in progresso("Transcrevendo: " + msg, p) }
            }
            let res = try await withTaskCancellationHandler { try await trabalho.value } onCancel: { trabalho.cancel() }
            r = res
            let g = TranscricoesGuardadas.Guardada(versao: CrisperTranscritor.versao, texto: res.texto,
                                                   palavras: res.palavras, duracao: res.segundosAudio, criada: Date())
            TranscricoesGuardadas.gravar(g, para: url)
            guardada = g
        }
        guard var g = guardada else { throw ErroApp("Não consegui transcrever.") }
        // tempos das palavras pelo alinhador (guardados junto da transcrição)
        var palavras = g.palavras
        var alinhado = false
        if let a = g.alinhadas, g.versaoAlinhador == Alinhador.versao {
            palavras = a; alinhado = true
        } else if ModeloAlinhador.pronto {
            progresso("Alinhando as palavras", 0)
            liberar()                                  // o CrisperWhisper não é mais preciso: libera a memória
            Diagnostico.log("corte: memória antes do alinhador \(Memoria.agora() >> 20) MB")
            let ws = g.palavras
            let trabalho = Task.detached(priority: .userInitiated) {
                try Alinhador().alinhar(ws, audio: audio) { p in progresso("Alinhando as palavras", p) }
            }
            do {
                palavras = try await withTaskCancellationHandler { try await trabalho.value } onCancel: { trabalho.cancel() }
                alinhado = true
                Diagnostico.log("corte: alinhador ok, memória \(Memoria.agora() >> 20) MB")
                g.alinhadas = palavras; g.versaoAlinhador = Alinhador.versao
                TranscricoesGuardadas.gravar(g, para: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // alinhador falhou: segue com os tempos do CrisperWhisper (o painel avisa "sem alinhador")
                palavras = g.palavras
                Diagnostico.log("alinhador falhou: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        progresso("Calculando os cortes", nil)
        let dur = Double(audio.count) / 16000
        let cortes = CorteAutomatico.cortes(palavras, audio: audio)
        let manter = CorteAutomatico.manter(cortes, duracao: dur)
        var p = PropostaCorte(duracao: dur, texto: g.texto, manter: manter,
                              tirar: cortes.map { .init(i: $0.i, f: $0.f, texto: $0.motivo) })
        p.reparos = r?.reparos ?? 0
        p.recomecos = r?.recomecos ?? 0
        p.fimRecuperado = r?.fimRecuperado ?? 0
        p.transcricaoGuardada = r == nil
        p.alinhado = alinhado
        p.pastaDiagnostico = Self.diagnostico(p, original: g.palavras, usadas: palavras, url: url)
        return p
    }

    /// Grava em "No meu iPhone › Estúdio › CrisperWhisper-testes › <data> <nome>" as palavras (tempos do
    /// CrisperWhisper e do alinhador) e a lista do que saiu e por quê. Devolve o nome da pasta.
    static func diagnostico(_ p: PropostaCorte, original: [PalavraTempo], usadas: [PalavraTempo], url: URL) -> String? {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let nome = fmt.string(from: Date()) + " " + String(url.deletingPathExtension().lastPathComponent.prefix(40))
        let pasta = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrisperWhisper-testes", isDirectory: true)
            .appendingPathComponent(nome, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            struct Palavras: Codable { var crisperwhisper: [PalavraTempo]; var usadas: [PalavraTempo]; var alinhado: Bool }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(Palavras(crisperwhisper: original, usadas: usadas, alinhado: p.alinhado))
                .write(to: pasta.appendingPathComponent("palavras.json"))
            try relatorio(p, nome: url.lastPathComponent).write(to: pasta.appendingPathComponent("cortes.txt"),
                                                                 atomically: true, encoding: .utf8)
            return nome
        } catch { return nil }
    }

    /// Texto do que saiu, para acompanhar o áudio cortado.
    static func relatorio(_ p: PropostaCorte, nome: String) -> String {
        func tempo(_ s: Double) -> String { String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
        let fica = p.manter.reduce(0) { $0 + ($1.f - $1.i) }
        var linhas = [
            "Corte automático de \(nome)",
            "Fica \(tempo(fica)) de \(tempo(p.duracao)) · \(p.tirar.count) cortes · regra v4 · tempos "
                + (p.alinhado ? "do alinhador" : "do CrisperWhisper (alinhador ausente ou falhou)"),
            "",
            "O que saiu (tempos no original) e por quê:",
        ]
        linhas += p.tirar.map { "\(tempo($0.i)) a \(tempo($0.f))  \($0.texto)" }
        linhas += ["", "Transcrição completa (tudo o que foi dito):", p.texto]
        return linhas.joined(separator: "\n") + "\n"
    }
}
